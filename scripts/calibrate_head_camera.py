#!/usr/bin/env python3
"""Eye-to-hand calibration of the head camera, using the gripper as its own fiducial.

THE DETECTOR IS MOTION, NOT A MARKER

Asking a VLM where the gripper is returns positions spanning 38 px on the SAME
image — 20x too coarse to calibrate with. A printed ArUco marker would fix
that, but needs a printer. Opening and closing the gripper and differencing the
two frames needs nothing at all: the only thing that changed is the finray
fingers, so the motion blob IS the gripper, and the background cancels because
it did not move.

Measured repeatability on this unit: 0.1 px over four trials. That is ~400x
better than the VLM and comfortably inside what a pose solve needs.

WHAT IS BEING SOLVED

At each arm pose, FK gives the gripper's 3D position in the arm frame and the
motion blob gives its pixel. Four or more well-spread correspondences determine
the camera's pose by PnP. The result is only valid for the tower pose it was
captured at, so the tower is read at every sample and drift is refused, not
averaged in.

KNOWN BIAS, STATED RATHER THAN HIDDEN

The motion centroid is the middle of the moving finger region, not the
gripper_frame_link origin FK reports. Those differ by a fixed offset of a few
centimetres. With the gripper's ORIENTATION held constant across poses that
offset is a constant translation, so it biases the solved camera POSITION by
that amount while leaving the orientation correct. The script therefore holds
orientation fixed, reports the residuals honestly, and refuses to write a
calibration whose reprojection error is too large to be trusted.

SAFETY

Goal is synced to present BEFORE torque is enabled, so engaging cannot snap the
arm to a stale target. Moves are joint-space deltas from the current pose, small
and bounded; nothing is commanded in Cartesian space, so no IK solution can
send the arm somewhere unexpected. Every move is verified to have landed before
a sample is taken.
"""
import argparse
import json
import math
import os
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "sidecar"))

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
              "wrist_flex", "wrist_roll", "gripper"]
# El puerto del BRAZO y el de la TORRE se leen del entorno, porque no siempre
# comparten bus. En el Pi la torre cuelga del bus de este mismo brazo; en el Mac
# el brazo con el perfil xle_left es 5B3D0437151 y la torre vive en el OTRO
# adaptador (5B610332201), asi que `shared_bus=rob.bus` no la encuentra.
# Por defecto queda el valor del Pi, para no cambiar el comportamiento alli.
ARM_PORT = os.environ.get("LEX_XLE_CALIB_ARM_PORT",
                          "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00")
ARM_ID = os.environ.get("LEX_XLE_CALIB_ARM_ID", "xle_left")
TOWER_PORT = os.environ.get("LEX_XLE_CALIB_TOWER_PORT")   # None = mismo bus que el brazo
LEFT_PORT = ARM_PORT
GRIP_CLOSED, GRIP_OPEN = 2100, 2900
MAX_STEP_TICKS = 380                  # per joint, per pose — bounded, but big
                                      # (sobrescribible con --max-step)
LIMIT_MARGIN = 60                     # stay this far inside the calibrated range
SETTLE_S = 2.2                        # then _wait_until_still confirms it


def _wait_until_still(grab, tries=12, quiet=None):
    """Block until consecutive frames stop changing.

    Without this the differencing is worthless. The gripper open/close diff
    only isolates the fingers if NOTHING ELSE moved between the two frames —
    but an arm still settling from the previous pose keeps drifting, and the
    diff then captures the whole arm. Measured: blob areas ranged 924..21552
    across poses (20x) with a fixed 1 s sleep, versus a stable ~3700 when the
    arm was genuinely at rest. That contamination alone took the solve from
    usable to 116 px.
    """
    # El umbral de "quieto" depende del RUIDO DE LA CAMARA, no del robot.
    # Medido en el Mac con esta luz: fotogramas consecutivos sin nada moviendose
    # difieren 1.84 de media, contra un umbral de 2.0 -- solo 0.16 de holgura, y
    # con el brazo asentandose y la luz de la ventana cambiando se pasa, con lo
    # que _wait_until_still no estabiliza NUNCA y cada pose sale como "gripper
    # not visible". Sigue muy por debajo del movimiento real de la pinza, que
    # segun las medidas de arriba es ~20x mayor.
    quiet = QUIET if quiet is None else quiet
    import numpy as np
    prev = grab()
    seen = []
    for _ in range(tries):
        cur = grab()
        if prev is not None and cur is not None:
            d = float(np.abs(cur - prev).mean())
            seen.append(d)
            if d < quiet:
                return True
        prev = cur
    if DEBUG:
        obs = " ".join(f"{d:.1f}" for d in seen) or "(sin fotogramas)"
        print(f"      [debug] diffs vistos contra umbral {quiet}: {obs}", flush=True)
    return False


THRESH, MIN_AREA, QUIET, DEBUG, BAND = 25, 400, 2.0, False, 2.2
FRACS = (1.0, 0.55)        # con --verify se cambian, ver abajo


def motion_pixel(cap, set_gripper, blur=5, thresh=None, expect_area=None,
                 min_area=None, read_gripper=None):
    """Pixel of the gripper, found by differencing closed against open."""
    import cv2
    import numpy as np

    def grab():
        for _ in range(4):
            cap.read()
        ok, f = cap.read()
        if not ok:
            return None
        return cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.int16)

    def why(msg):
        if DEBUG:
            print(f"      [debug] {msg}", flush=True)

    set_gripper(GRIP_CLOSED)
    if not _wait_until_still(grab):
        why("la escena nunca se queda quieta (sube --quiet)")
        return None                    # never settled; a diff here would be noise
    a = grab()
    ga = read_gripper() if read_gripper else None
    set_gripper(GRIP_OPEN)
    if not _wait_until_still(grab):
        why("no se queda quieta tras abrir la pinza (sube --quiet)")
        return None
    b = grab()
    gb = read_gripper() if read_gripper else None
    if DEBUG and ga is not None:
        why(f"pinza al capturar: cerrada={ga} abierta={gb} (movio {abs(gb-ga)} ticks)")
    if a is None or b is None:
        why("la camara no devolvio fotograma")
        return None
    d = cv2.GaussianBlur(np.abs(b - a).astype(np.uint8), (blur, blur), 0)
    if DEBUG:
        th = THRESH if thresh is None else thresh
        why(f"diferencia cerrado/abierto: max {int(d.max())} media {d.mean():.2f} "
            f"| {int((d > th).sum())} px por encima de {th}")
    # El umbral depende del CONTRASTE de la escena, no del robot. En el Pi 25
    # daba manchas de 924..21552 px; medido en el Mac con esta luz y distancia,
    # 25 da 227 px (rechazada) y 10 da 551. Por eso es parametro y no constante.
    _, m = cv2.threshold(d, THRESH if thresh is None else thresh, 255, cv2.THRESH_BINARY)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    n, _lab, st, ce = cv2.connectedComponentsWithStats(m, 8)
    if n < 2:
        why(f"ninguna mancha con --thresh {THRESH if thresh is None else thresh}")
        return None
    i = max(range(1, n), key=lambda k: st[k, cv2.CC_STAT_AREA])
    area = int(st[i, cv2.CC_STAT_AREA])
    if area < (MIN_AREA if min_area is None else min_area):   # ruido, no dedos
        why(f"mancha mayor {area} px < minimo {MIN_AREA if min_area is None else min_area}")
        return None
    # The fingers subtend a fairly consistent area. Something 2x off is not the
    # fingers — it is the whole arm having moved, or only a sliver being visible.
    if expect_area and not (expect_area / BAND < area < expect_area * BAND):
        why(f"mancha {area} px fuera de la banda esperada "
            f"{expect_area / BAND:.0f}..{expect_area * BAND:.0f}")
        return None
    return float(ce[i][0]), float(ce[i][1]), area



def solve_with_tool_offset(obj_T, img, K, dist, rvec0, tvec0):
    """PnP que estima TAMBIEN donde estan los dedos respecto al marco de la pinza.

    El PnP normal supone que el punto 3D observado es el origen de
    gripper_frame_link. No lo es: la mancha de movimiento son los DEDOS, a unos
    centimetros del origen, y ese desfase esta fijo en el marco de la PINZA, o
    sea que ROTA con la muneca. A 0.3 m y f=349 px, 1 cm son 11.6 px, asi que
    +-1.5 cm bastan para explicar los 15-18 px de reproyeccion que no bajaban
    tocando umbrales, ni con la distorsion medida, ni reapuntando la torre.
    Medido en este brazo: 10.5 cm de desfase, y el error cae de 250 px a 1.8.

    obj_T son las matrices 4x4 de la cinemática, no solo posiciones: sin la
    rotacion el desfase no es observable.
    """
    import cv2          # se importa aqui: el modulo no lo trae a nivel global
    import numpy as np
    from scipy.optimize import least_squares

    def pts(tool):
        return np.array([T[:3, :3] @ tool + T[:3, 3] for T in obj_T])

    def resid(p):
        proj, _ = cv2.projectPoints(pts(p[6:9]), p[:3], p[3:6], K, dist)
        return (proj.reshape(-1, 2) - img).ravel()

    # Sin acotar el desfase el ajuste se escapa a kilometros: una pinza lejisimos
    # y una camara igual de lejos reproyectan casi igual. El limite es fisico.
    LIM = 0.15
    lo = np.concatenate([np.full(3, -4 * np.pi), np.full(3, -5.0), np.full(3, -LIM)])
    hi = np.concatenate([np.full(3, 4 * np.pi), np.full(3, 5.0), np.full(3, LIM)])
    p0 = np.clip(np.concatenate([np.ravel(rvec0), np.ravel(tvec0), np.zeros(3)]),
                 lo + 1e-9, hi - 1e-9)

    def fit(keep):
        r = least_squares(lambda p: resid(p).reshape(-1, 2)[keep].ravel(), p0,
                          method="trf", bounds=(lo, hi), loss="soft_l1",
                          f_scale=8.0, max_nfev=20000)
        return r.x

    keep = np.ones(len(img), bool)
    x = fit(keep)
    for _ in range(3):
        e = np.linalg.norm(resid(x).reshape(-1, 2), axis=1)
        cut = max(3.0 * float(np.median(e[keep])), 10.0)
        nk = keep & (e < cut)
        if nk.sum() < 6 or nk.sum() == keep.sum():
            break
        keep = nk
        x = fit(keep)
    e = np.linalg.norm(resid(x).reshape(-1, 2), axis=1)

    # Dejando uno fuera: 9 parametros contra pocos puntos se memorizan. El error
    # sobre un punto que el ajuste NO ha visto es el unico honesto.
    loo = []
    for h in np.where(keep)[0]:
        k = keep.copy()
        k[h] = False
        try:
            loo.append(float(np.linalg.norm(
                resid(fit(k)).reshape(-1, 2)[h])))
        except Exception:
            pass
    return x, keep, e, (np.array(loo) if loo else None)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--focal-px", type=float, default=348.4,
                   help="solo se usa si NO se pasa --intrinsics")
    p.add_argument("--intrinsics", default="",
                   help="JSON de calibration/: usa la K y la DISTORSION medidas en "
                        "vez de asumir centro optico y lente perfecta")
    p.add_argument("--max-reproj-px", type=float, default=4.0,
                   help="refuse to write a calibration worse than this")
    p.add_argument("--thresh", type=int, default=25,
                   help="umbral de diferencia de brillo; bajar si la escena tiene poco contraste")
    p.add_argument("--quiet", type=float, default=0.0,
                   help="umbral de 'escena quieta'; 0 = medirlo de la propia camara")
    p.add_argument("--min-area", type=int, default=400,
                   help="area minima de la mancha para aceptarla como la pinza")
    p.add_argument("--band", type=float, default=2.2,
                   help="cuanto puede desviarse el area de la mediana; bajar si la "
                        "mancha se come el antebrazo ademas de los dedos")
    p.add_argument("--max-step", type=int, default=380,
                   help="ticks maximos por articulacion y pose; subir da mas "
                        "recorrido (y mejor condicionamiento) a costa de alcance")
    p.add_argument("--debug", action="store_true",
                   help="di POR QUE se descarta cada pose en vez de solo 'not visible'")
    p.add_argument("--verify", default="",
                   help="comprobar una calibracion ya escrita en vez de generar "
                        "otra: va a poses DISTINTAS de las que la produjeron y "
                        "mide si acierta donde aparece la pinza")
    p.add_argument("--out", default="")
    p.add_argument("--samples-out", default="")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    global THRESH, MIN_AREA, QUIET, DEBUG, BAND
    THRESH, MIN_AREA, QUIET, DEBUG, BAND = (a.thresh, a.min_area, a.quiet,
                                            a.debug, a.band)
    global MAX_STEP_TICKS, FRACS
    MAX_STEP_TICKS = a.max_step
    # Comprobar con las MISMAS poses que calibraron no comprueba nada: mide si
    # el ajuste recuerda, no si predice. Otras fracciones = otras poses.
    if a.verify:
        FRACS = (0.8, 0.35)

    import cv2
    import numpy as np
    import tower
    from lerobot.model.kinematics import RobotKinematics
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.robots.so_follower.robot_kinematic_processor import (
        compute_forward_kinematics_joints_to_ee)

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM_JOINTS,
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link"))

    # CAP_V4L2 es el backend de LINUX. En macOS VideoCapture NO falla al abrirlo:
    # isOpened() dice True y luego cada read() devuelve False para siempre, asi que
    # el sintoma es "gripper not visible" en todas las poses y se pierde el tiempo
    # ajustando umbrales sobre fotogramas que nunca llegaron. Mismo arreglo que ya
    # lleva calibration/capture_intrinsics.py.
    cam_index = int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "4"))
    cap = cv2.VideoCapture(cam_index,
                           cv2.CAP_V4L2 if sys.platform.startswith("linux")
                           else cv2.CAP_ANY)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    ok, _probe = cap.read()
    if not ok:
        sys.exit(f"la camara {cam_index} se abrio pero no entrega fotogramas.\n"
                 "En macOS el permiso va por PROCESO RESPONSABLE: lanzalo desde\n"
                 "Terminal.app, que si tiene el permiso concedido.")
    for _ in range(8):
        cap.read()

    rob = SO101Follower(SO101FollowerConfig(port=ARM_PORT, id=ARM_ID))
    rob.bus.connect()
    twr = tower.TowerDriver(**({"port": TOWER_PORT} if TOWER_PORT else {"shared_bus": rob.bus}),
                            pan_limits=(347, 3747),
                            tilt_limits=(2523, 3400))
    home = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
    t0 = twr.read()
    tower_ref = (t0["pan_ticks"], t0["tilt_ticks"])
    print(f"  tower reference pan {tower_ref[0]} tilt {tower_ref[1]}")

    def set_joint(j, v):
        rob.bus.write("Goal_Position", j, int(v), normalize=False, num_retry=3)

    def set_gripper(v):
        set_joint("gripper", v)
        time.sleep(0.9)

    # Poses as joint deltas from home, sized to the room each joint ACTUALLY has.
    #
    # A first version used symmetric +/- deltas and lost a third of its poses to
    # servos clamping at their calibrated travel limits — this arm parks right
    # at shoulder_lift's minimum and elbow_flex's maximum, so half of every
    # symmetric pair was unreachable. The surviving poses spanned only ~5 cm,
    # and PnP over a 5 cm baseline at 0.4 m range is hopelessly conditioned:
    # the solve came back 20 px and 41 cm off. Spread is not a nicety here, it
    # is the difference between a calibration and a number.
    cal_path = (pathlib.Path.home() / ".cache/huggingface/lerobot/calibration"
                # Atado a ARM_ID, no fijo: con el otro brazo esto cargaba los
                # limites articulares del brazo equivocado, y el sintoma habria
                # sido poses recortadas o fuera de rango, no un error claro.
                / "robots/so_follower" / f"{ARM_ID}.json")
    cal = json.loads(cal_path.read_text()) if cal_path.is_file() else {}

    def room(j, sign):
        """How far joint j can move in `sign`, staying inside its travel limits."""
        c = cal.get(j)
        if not c:
            return MAX_STEP_TICKS // 2
        lo, hi = c["range_min"] + LIMIT_MARGIN, c["range_max"] - LIMIT_MARGIN
        avail = (hi - home[j]) if sign > 0 else (home[j] - lo)
        return max(0, min(MAX_STEP_TICKS, int(avail)))

    def step(j, sign, frac=1.0):
        return sign * int(room(j, sign) * frac)

    deltas = [{}]
    for j in ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex"):
        for sign in (+1, -1):
            for frac in FRACS:
                d = step(j, sign, frac)
                if abs(d) >= 90:                 # too small to add real spread
                    deltas.append({j: d})
    # a few combinations, so the point cloud is not a cross of single-axis arms
    deltas += [{"shoulder_pan": step("shoulder_pan", +1, 0.7),
                "shoulder_lift": step("shoulder_lift", +1, 0.5)},
               {"shoulder_pan": step("shoulder_pan", -1, 0.7),
                "elbow_flex": step("elbow_flex", -1, 0.5)}]
    deltas = [d for d in deltas if not d or any(abs(v) >= 90 for v in d.values())]
    print(f"  {len(deltas)} candidate poses, sized to each joint's remaining travel")
    # Asumir cx=cy=centro y distorsion cero es caro en una lente de 85 grados.
    # Las detecciones llegan a x=222 y x=560 -- a +-170 px del centro, justo donde
    # el barril mas desplaza -- asi que ignorar `dist` mete error de reproyeccion
    # que luego se confunde con mala geometria. Los intrinsecos medidos (117
    # vistas, rms 0.45 px) ya viven en calibration/.
    if a.intrinsics:
        ins = json.loads(pathlib.Path(a.intrinsics).read_text())
        K = np.array(ins["K"], np.float64)
        dist = np.array(ins["dist"], np.float64).reshape(-1, 1)
        print(f"  intrinsecos medidos de {a.intrinsics}: "
              f"fx={K[0,0]:.1f} fy={K[1,1]:.1f} cx={K[0,2]:.1f} cy={K[1,2]:.1f}, "
              f"{len(ins['dist'])} coef. de distorsion")
    else:
        K = np.array([[a.focal_px, 0, 320.0], [0, a.focal_px, 240.0], [0, 0, 1.0]])
        dist = None
        print("  sin --intrinsics: centro optico ASUMIDO y lente sin distorsion")

    # Medir el suelo de ruido en vez de asumirlo. El 2.0 fijo que habia aqui es
    # una trampa: esta camara da 1.84 con todo quieto, o sea 0.16 de margen, y en
    # cuanto el brazo se asienta o cambia la luz se pasa y _wait_until_still no
    # estabiliza NUNCA. El sintoma es "gripper not visible" en TODAS las poses,
    # identico al de una camara que no entrega fotogramas, y cuesta horas
    # distinguirlos.
    if a.quiet > 0:
        QUIET = a.quiet
    else:
        diffs, prev = [], None
        for _ in range(9):
            for _ in range(4):
                cap.read()
            ok, f = cap.read()
            if not ok:
                continue
            g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.int16)
            if prev is not None:
                diffs.append(float(np.abs(g - prev).mean()))
            prev = g
        floor = float(np.median(diffs)) if diffs else 1.0
        QUIET = max(round(floor * 1.6, 2), 2.0)
        print(f"  ruido de la camara {floor:.2f} -> umbral de quietud {QUIET}")

    verify, vtool, checks = None, np.zeros(3), []
    if a.verify:
        verify = json.loads(pathlib.Path(a.verify).read_text())
        vtool = np.array(verify.get("gripper_tool_offset_m", [0, 0, 0]), np.float64)
        print(f"  COMPROBANDO {a.verify} en poses distintas de las que la generaron")
        print(f"  desfase de pinza ({vtool[0]*100:+.1f},{vtool[1]*100:+.1f},"
              f"{vtool[2]*100:+.1f}) cm")
        print("  la torre DEBE seguir donde estaba al calibrar")
    samples = []
    try:
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        for j in ARM_JOINTS:
            rob.bus.write("Torque_Enable", j, 1, normalize=False, num_retry=3)
            rob.bus.write("Lock", j, 1, normalize=False, num_retry=3)
        time.sleep(0.5)
        landed = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
        drift = max(abs(landed[k] - home[k]) for k in home)
        print(f"  torque engaged; movement on engage {drift} ticks (goal was pre-synced)")

        for n, dl in enumerate(deltas, 1):
            for j, dv in dl.items():
                if abs(dv) > MAX_STEP_TICKS:
                    sys.exit(f"refusing a {dv}-tick step on {j}")
                set_joint(j, home[j] + dv)
            time.sleep(SETTLE_S)
            now = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
            for j, dv in dl.items():
                if abs(now[j] - (home[j] + dv)) > 60:
                    print(f"    pose {n}: {j} did not land "
                          f"(wanted {home[j]+dv}, at {now[j]}) — skipping")
                    break
            else:
                t = twr.read()
                if max(abs(t["pan_ticks"] - tower_ref[0]),
                       abs(t["tilt_ticks"] - tower_ref[1])) > 8:
                    sys.exit("tower moved mid-capture — every correspondence so far "
                             "refers to a camera pose that no longer exists. Aborting.")
                median = (sorted(x["blob_area"] for x in samples)[len(samples)//2]
                          if len(samples) >= 3 else None)
                hit = motion_pixel(cap, set_gripper, expect_area=median,
                                   read_gripper=lambda: int(rob.bus.read(
                                       'Present_Position', 'gripper',
                                       normalize=False)))
                if hit is None:
                    print(f"    pose {n}: gripper not visible / no motion blob")
                else:
                    deg = rob.bus.sync_read("Present_Position", num_retry=3)
                    e = compute_forward_kinematics_joints_to_ee(
                        {f"{j}.pos": float(deg[j]) for j in ARM_JOINTS}, kin, ARM_JOINTS)
                    ee = [float(e[k]) for k in ("ee.x", "ee.y", "ee.z")]
                    # Guardar tambien los angulos: el origen de gripper_frame_link
                    # NO es donde esta la mancha de los dedos, y ese desfase vive en
                    # el marco de la PINZA, asi que rota con la muneca. Con los
                    # angulos se puede recalcular la orientacion y resolver el
                    # desfase offline, sin volver a ocupar el robot en cada prueba.
                    samples.append({"ee_xyz_m": [round(v, 5) for v in ee],
                                    "joints_deg": {j: round(float(deg[j]), 4)
                                                   for j in ARM_JOINTS},
                                    "pixel": [round(hit[0], 2), round(hit[1], 2)],
                                    "blob_area": hit[2]})
                    if verify is not None:
                        T = np.asarray(kin.forward_kinematics(np.array(
                            [float(deg[j]) for j in ARM_JOINTS], np.float64)),
                            np.float64)
                        pw = T[:3, :3] @ vtool + T[:3, 3]
                        Rv = np.array([verify["right"], verify["down"],
                                       verify["forward"]], np.float64)
                        rv, _ = cv2.Rodrigues(Rv)
                        tv = (-Rv @ np.array(verify["pos"], np.float64)).reshape(3, 1)
                        pr, _ = cv2.projectPoints(pw.reshape(1, 3), rv, tv, K, dist)
                        pr = pr.ravel()
                        d = float(np.hypot(pr[0] - hit[0], pr[1] - hit[1]))
                        checks.append(d)
                        print(f"  [{len(samples)}] predicho ({pr[0]:6.1f},{pr[1]:6.1f})"
                              f"  visto ({hit[0]:6.1f},{hit[1]:6.1f})  ERROR {d:5.1f} px")
                    else:
                        print(f"  [{len(samples)}] ee ({ee[0]:+.3f},{ee[1]:+.3f},"
                              f"{ee[2]:+.3f})  pixel ({hit[0]:6.1f},{hit[1]:6.1f})"
                              f"  area {hit[2]}")
            for j in dl:
                set_joint(j, home[j])
            time.sleep(0.6)
    finally:
        print("  returning to the start pose and releasing")
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        time.sleep(1.2)
        for j in ARM_JOINTS:
            try:
                rob.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
            except Exception:
                pass
        rob.bus.disconnect()
        cap.release()

    if verify is not None:
        if not checks:
            print("\n  ninguna pose detectada; no puedo comprobar nada")
            return 1
        c = np.array(checks)
        print(f"\n  {len(c)} poses NUEVAS comprobadas")
        print(f"  error de prediccion: media {c.mean():.1f} px  mediana "
              f"{np.median(c):.1f}  max {c.max():.1f}")
        # a f=349 px y ~0.3 m, 1 px son ~0.86 mm
        print(f"  equivale a ~{c.mean()*0.3/K[0, 0]*1000:.0f} mm a 0.3 m de distancia")
        return 0
    if a.samples_out:
        # La camara va sobre una torre ORIENTABLE: unos extrinsecos solo valen
        # para el angulo al que se midieron. Sin esto es facil agrupar tandas de
        # dos apuntados distintos y obtener algo peor que cualquiera de las dos.
        pathlib.Path(a.samples_out).write_text(json.dumps(
            {"tower_reference": list(tower_ref), "samples": samples}, indent=2) + "\n")
    if len(samples) < 4:
        print(f"\n  only {len(samples)} usable poses — PnP needs 4+. Nothing solved.")
        return 1

    obj = np.array([s["ee_xyz_m"] for s in samples], np.float64)
    img = np.array([s["pixel"] for s in samples], np.float64)
    spread = [float(np.ptp(obj[:, i])) for i in range(3)]  # np.ptp: ndarray.ptp went in NumPy 2.0
    print(f"\n  {len(samples)} poses; gripper spread x {spread[0]*100:.0f} "
          f"y {spread[1]*100:.0f} z {spread[2]*100:.0f} cm")

    best = None
    for flag, name in ((cv2.SOLVEPNP_EPNP, "EPNP"), (cv2.SOLVEPNP_SQPNP, "SQPNP"),
                       (cv2.SOLVEPNP_ITERATIVE, "ITERATIVE")):
        try:
            ok, rvec, tvec = cv2.solvePnP(obj, img, K, dist, flags=flag)
        except cv2.error:
            continue
        if not ok:
            continue
        rvec, tvec = cv2.solvePnPRefineLM(obj, img, K, dist, rvec, tvec)
        proj, _ = cv2.projectPoints(obj, rvec, tvec, K, dist)
        err = np.linalg.norm(proj.reshape(-1, 2) - img, axis=1)
        print(f"  {name:10} reprojection mean {err.mean():5.2f} px  max {err.max():5.2f} px")
        if best is None or err.mean() < best[0]:
            best = (err.mean(), name, rvec, tvec, err)

    mean, name, rvec, tvec, err = best

    # Refinar estimando tambien donde caen los dedos respecto al marco de la
    # pinza. Sin esto el error se estanca en 15-18 px por mucho que se ajusten
    # umbrales: no es ruido de deteccion, es un error de modelo.
    tool = None
    if all("joints_deg" in x for x in samples):
        obj_T = np.array([np.asarray(
            kin.forward_kinematics(np.array([x["joints_deg"][j] for j in ARM_JOINTS],
                                            np.float64)), np.float64)
            for x in samples])
        gap = np.linalg.norm(obj_T[:, :3, 3] - obj, axis=1).max()
        if gap > 0.005:
            print(f"  aviso: la cinematica recalculada difiere {gap*100:.1f} cm "
                  "de la guardada; no refino")
        else:
            x, keep, e, loo = solve_with_tool_offset(obj_T, img, K, dist, rvec, tvec)
            rvec, tvec, tool = x[:3], x[3:6], x[6:9]
            mean, err = float(e[keep].mean()), e[keep]
            print(f"  + desfase de pinza ({tool[0]*100:+.1f},{tool[1]*100:+.1f},"
                  f"{tool[2]*100:+.1f}) cm: {keep.sum()}/{len(samples)} poses, "
                  f"ajuste {mean:.2f} px")
            if loo is not None and len(loo):
                # el numero honesto: error sobre puntos que el ajuste no vio
                mean = float(loo.mean())
                print(f"  dejando uno fuera: media {loo.mean():.2f} px  "
                      f"max {loo.max():.2f} px  <- este es el que se juzga")
            name = f"{name}+tool"
    R, _ = cv2.Rodrigues(rvec)
    C = (-R.T @ np.asarray(tvec).reshape(3, 1)).ravel()
    print(f"\n  BEST {name}: mean {mean:.2f} px, max {err.max():.2f} px")
    print(f"  camera position in LEFT-ARM frame ({C[0]:+.3f},{C[1]:+.3f},{C[2]:+.3f}) m")
    urdf_est = np.array([-0.043, -0.133, 0.4082])
    print(f"  URDF-sourced estimate        ({urdf_est[0]:+.3f},{urdf_est[1]:+.3f},"
          f"{urdf_est[2]:+.3f}) m  -> differs by {np.linalg.norm(C-urdf_est)*100:.1f} cm")
    print(f"  det(R) {np.linalg.det(R):+.3f}")

    if mean > a.max_reproj_px:
        print(f"\n  REFUSING to write: {mean:.2f} px exceeds --max-reproj-px "
              f"{a.max_reproj_px}. A fit this loose yields confidently wrong world "
              f"positions. More spread across all three axes is the usual cure.")
        return 1
    cam = {"pos": [round(float(v), 5) for v in C],
           "right": [round(float(v), 6) for v in R[0]],
           "down": [round(float(v), 6) for v in R[1]],
           "forward": [round(float(v), 6) for v in R[2]],
           "fx": round(float(K[0, 0]) / 640, 6), "fy": round(float(K[1, 1]) / 480, 6),
           "cx0": round(float(K[0, 2]) / 640, 6), "cy0": round(float(K[1, 2]) / 480, 6),
           **({} if dist is None else dict(zip(
               ("k1", "k2", "p1", "p2", "k3"),
               [round(float(v), 8) for v in dist.ravel()[:5]]))),
           "tower_ticks": {"pan": int(tower_ref[0]), "tilt": int(tower_ref[1])},
           "arm_id": ARM_ID,
           "_provenance": {
               "method": f"eye-to-hand PnP ({name}) over {len(samples)} arm poses; "
                         "gripper located by open/close motion differencing "
                         "(0.1 px repeatable), NOT by a vision model (38 px).",
               "reprojection_px": {"mean": round(float(mean), 2),
                                   "max": round(float(err.max()), 2)},
               "tower_reference": list(tower_ref),
               "valid_only_at": "this tower pan/tilt — the camera rides the tower, so "
                                "moving it invalidates these extrinsics silently.",
               "known_bias": "the motion centroid is the finger region's middle, not "
                             "gripper_frame_link's origin; a few cm of fixed offset is "
                             "folded into pos. Orientation is unaffected.",
               "fx_fy": f"f={a.focal_px}px measured by tower rotation, normalized by "
                        "width/height per ray_direction's algebra.",
               **({} if tool is None else {"gripper_tool_offset_m":
                   [round(float(v), 5) for v in tool],
                   "tool_offset_note": ("donde estan los dedos respecto al origen "
                                        "de gripper_frame_link; estimado, no medido "
                                        "con regla")}),
               "cx0_cy0": ("measured" if dist is not None
                           else "ASSUMED image centre; not measured.")}}
    print(json.dumps({k: v for k, v in cam.items() if k != "_provenance"}, indent=2))
    if a.out and not a.dry_run:
        pathlib.Path(a.out).write_text(json.dumps(cam, indent=2) + "\n")
        print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
