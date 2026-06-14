#!/usr/bin/env python3
"""Behavior-cloning reach policy for the depot G1 — a *learned* controller.

The depot gifs are driven by a hand-written servo (a mocap-weld teleop shortcut):
the motion is scripted by us, not decided by the robot. This script answers
"could a learned policy do it instead?" with the smallest honest experiment:

  1. COLLECT — use the scripted servo as an "expert" to reach many random goal
     points, recording (observation, action) pairs. Observation = right-arm joint
     angles (7) + connector-tip position (3) + goal position (3). Action = the
     arm joint angles one control-step later.
  2. TRAIN — fit a tiny MLP by behaviour cloning (MSE) to imitate the expert.
  3. ROLLOUT — drive the arm with the *learned* policy in closed loop: position
     actuators on the right arm track the network's predicted joint targets. No
     servo, no weld at rollout — the network decides the motion. Generalisation
     to goals it never saw (incl. the real charge inlet) is the test.

This is genuinely autonomous *control* (the net maps state+goal -> joint targets),
though the goal still comes from Perceive and there's no vision — proprioception
+ goal only. It is a quick BC, so expect a fraction of held-out goals to miss and
the un-actuated free base to throw transient "unstable" warnings (the base is
hard-pinned each step; the run stays finite). The point is the seam: swap the
scripted servo for a learned policy and the Lex governance layer is unchanged.

Runs in the pinned depot model (gravity off) so the arm is the only variable.

Deps: pip install mujoco numpy torch  (+ the G1 model via LEX_G1_DIR).
Run:  python3 sidecar/g1_bc_reach.py        # trains, evaluates, writes a gif
"""

import importlib.util
import os
import sys

import numpy as np

try:
    import mujoco
    import torch
    import torch.nn as nn
except ImportError:
    sys.exit("g1_bc_reach needs: pip install mujoco numpy torch")

HERE = os.path.dirname(os.path.abspath(__file__))
SUB = 10          # physics steps per control step
GOAL_LO = np.array([0.27, -0.24, 0.80])   # reachable goal box (world)
GOAL_HI = np.array([0.39, -0.06, 0.97])
DEV = "mps" if torch.backends.mps.is_available() else "cpu"


def _load_depot_module():
    os.environ.setdefault("LEX_G1_BALANCE", "0")   # pinned model
    spec = importlib.util.spec_from_file_location(
        "depot_g1_sidecar", os.path.join(HERE, "depot_g1_sidecar.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    np.random.seed(0)
    torch.manual_seed(0)
    mod = _load_depot_module()
    D = mod.DEPOT
    m, d = D.m, D.d
    arm_acts = D.arm_acts
    arm_q = [int(m.jnt_qposadr[int(m.actuator_trnid[i, 0])]) for i in arm_acts]
    tip, mid, HAND = D.s_tip, D.mocap, mod.HAND
    WS_LO, WS_HI = mod.WS_LO, mod.WS_HI

    def sample_goal():
        return np.random.uniform(GOAL_LO, GOAL_HI)

    # 1) COLLECT expert demonstrations with the scripted servo.
    print("collecting expert demos ...")
    data = []
    for _ in range(90):
        g = sample_goal()
        D.reset()
        d.mocap_pos[mid] = d.body(HAND).xpos.copy()
        for c in range(70):
            q0 = np.array([d.qpos[i] for i in arm_q])
            t0 = d.site_xpos[tip].copy()
            for _ in range(SUB):
                err = g - d.site_xpos[tip]
                d.mocap_pos[mid] = np.clip(d.mocap_pos[mid] + 0.35 * err, WS_LO - 0.05, WS_HI + 0.05)
                mujoco.mj_step(m, d)
            data.append((np.concatenate([q0, t0, g]), np.array([d.qpos[i] for i in arm_q])))
            if np.linalg.norm(g - d.site_xpos[tip]) < 0.03 and c > 5:
                break
    X = np.array([o for o, _ in data], np.float32)
    Y = np.array([a for _, a in data], np.float32)

    # 2) TRAIN a tiny MLP by behaviour cloning.
    xm, xs = X.mean(0), X.std(0) + 1e-6
    ym, ys = Y.mean(0), Y.std(0) + 1e-6
    net = nn.Sequential(nn.Linear(13, 160), nn.ReLU(), nn.Linear(160, 160), nn.ReLU(), nn.Linear(160, 7)).to(DEV)
    opt = torch.optim.Adam(net.parameters(), 1e-3)
    xt = torch.tensor((X - xm) / xs, device=DEV)
    yt = torch.tensor((Y - ym) / ys, device=DEV)
    for _ in range(600):
        opt.zero_grad()
        loss = ((net(xt) - yt) ** 2).mean()
        loss.backward()
        opt.step()
    print(f"trained on {X.shape[0]} samples, final BC loss {float(loss.item()):.4f}")

    def policy(o):
        with torch.no_grad():
            return net(torch.tensor(((o - xm) / xs).astype(np.float32), device=DEV)).cpu().numpy() * ys + ym

    # 3) ROLLOUT with the learned policy: arm position actuators track the net's
    #    predicted joint targets. No servo, no teleop weld. The base (an
    #    un-actuated free joint) is hard-pinned each step so it can't drift.
    m2 = mod._build_spec().compile()
    d2 = mujoco.MjData(m2)
    aa = [i for i in range(m2.nu) if m2.actuator(i).name.startswith(("right_shoulder", "right_elbow", "right_wrist"))]
    aq = [int(m2.jnt_qposadr[int(m2.actuator_trnid[i, 0])]) for i in aa]
    tip2 = m2.site("tip").id
    mujoco.mj_resetDataKeyframe(m2, d2, 0)
    base_q = d2.qpos[0:7].copy()

    def rollout(goal, capture=None):
        mujoco.mj_resetDataKeyframe(m2, d2, 0)
        d2.eq_active[m2.equality("teleop").id] = 0
        d2.eq_active[m2.equality("basepin").id] = 0
        d2.eq_active[m2.equality("seat").id] = 0
        for i in range(m2.nu):
            d2.ctrl[i] = d2.qpos[m2.jnt_qposadr[int(m2.actuator_trnid[i, 0])]]
        mujoco.mj_forward(m2, d2)
        for _ in range(80):
            q0 = np.array([d2.qpos[i] for i in aq])
            t0 = d2.site_xpos[tip2].copy()
            tgt = policy(np.concatenate([q0, t0, goal]))
            for k, tv in zip(aa, tgt):
                d2.ctrl[k] = tv
            for _ in range(SUB):
                mujoco.mj_step(m2, d2)
                d2.qpos[0:7] = base_q
                d2.qvel[0:6] = 0
                mujoco.mj_forward(m2, d2)
            if capture is not None:
                capture()
        return float(np.linalg.norm(d2.site_xpos[tip2] - goal))

    np.random.seed(99)
    tests = [sample_goal() for _ in range(20)]
    inlet = d.site_xpos[D.s_inlet].copy()
    dists = [rollout(g) for g in tests]
    n_ok = sum(x < 0.06 for x in dists)
    print(f"learned-policy rollout (closed loop, no servo):")
    print(f"  held-out goals: {n_ok}/20 within 0.06 m  (median {np.median(dists):.3f} m)")
    print(f"  REAL charge inlet: {rollout(inlet):.4f} m  ({'reached' if rollout(inlet) < 0.06 else 'missed'})")

    # Render the learned-policy reach to the real inlet.
    try:
        from PIL import Image
    except ImportError:
        print("(install pillow to render the gif)")
        return
    R = mujoco.Renderer(m2, 480, 640)
    cam = mujoco.MjvCamera()
    cam.lookat[:] = [0.30, -0.12, 0.84]
    cam.distance, cam.azimuth, cam.elevation = 1.45, -112, -11
    frames = []
    R.update_scene(d2, cam)

    def cap():
        R.update_scene(d2, cam)
        frames.append(R.render().copy())

    rollout(inlet, capture=cap)
    # tint the port green to mark the connect, hold.
    for nm, rgba in (("led", [0.12, 0.95, 0.25, 1]), ("plug_g", [0.2, 1, 0.5, 1]), ("faceplate", [0.1, 0.4, 0.18, 1])):
        m2.geom_rgba[m2.geom(nm).id] = rgba
    for _ in range(14):
        cap()
    out = os.path.join(HERE, "..", "media", "depot_g1_policy.gif")
    imgs = [Image.fromarray(f) for f in frames]
    imgs[0].save(out, save_all=True, append_images=imgs[1:], duration=70, loop=0, optimize=True)
    print(f"wrote {os.path.normpath(out)} ({len(frames)} frames)")


if __name__ == "__main__":
    main()
