#!/usr/bin/env python
"""Calibracion mano-ojo: camara de cabeza -> brazo, sin tocar nada.

Tocar el tablero con la punta y leer la FK tiene un suelo medido de 13.2 mm
(ver repetibilidad_toque.json): con el par apagado el brazo se acomoda en
configuraciones distintas para tocar el mismo sitio, y el encoder del STS3215
esta en el eje de salida, asi que la holgura posterior es invisible.

Aqui la punta no interviene. La camara de la MUNECA mira el tablero desde
varias poses; en cada una se guardan las esquinas vistas y los angulos. Eso da

    T_brazo_pinza(i) @ X @ T_camara_tablero(i) = T_brazo_tablero   para toda i

con X (camara en el marco de la pinza) y T_brazo_tablero constantes y
desconocidas. Es el problema AX=ZB, que resuelve calibrateRobotWorldHandEye.
Combinado con lo que ve la camara de cabeza del mismo tablero, sale la pose de
esta ultima en el marco del brazo, que es lo que se buscaba.

Las mismas capturas sirven para los intrinsecos de la camara de muneca, que
tampoco teniamos: son vistas del tablero desde angulos variados, justo lo que
pide calibrateCamera.

    capture   mueve el brazo despacio; guarda solo poses suficientemente
              distintas de las ya guardadas, para no llenar el lote de vistas
              redundantes que no aportan condicionamiento.
    solve     intrinsecos -> solvePnP por vista -> AX=ZB, y valida midiendo
              cuanto varia T_brazo_tablero entre vistas, que en teoria es
              constante.
"""

import argparse
import json
import os
import time
from pathlib import Path

import cv2
import numpy as np

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex",
       "wrist_flex", "wrist_roll", "gripper"]
PORTS = {
    "right": "usb-1a86_USB_Single_Serial_5B61033220-if00",
    "left": "usb-1a86_USB_Single_Serial_5B3D045476-if00",
}
WRIST_CAM = {"right": "/dev/video2", "left": "/dev/video4"}
NX, NY = 9, 6
SQUARE_MM = 20.15


def objp():
    p = np.zeros((NX * NY, 3), np.float32)
    p[:, :2] = np.mgrid[0:NX, 0:NY].T.reshape(-1, 2) * SQUARE_MM
    return p


def open_bus(arm):
    from lerobot.motors import Motor, MotorCalibration, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus
    # La calibracion se pasa al construir el bus, no se escribe en los servos:
    # sin ella las lecturas en grados fallan, y escribirla tocaria su EEPROM.
    raw = json.loads((Path.home() / ".cache/huggingface/lerobot/calibration"
                      / "robots/so_follower" / f"xle_{arm}.json").read_text())
    bus = FeetechMotorsBus(
        port=f"/dev/serial/by-id/{PORTS[arm]}",
        motors={j: Motor(i + 1, "sts3215", MotorNormMode.DEGREES)
                for i, j in enumerate(ARM)},
        calibration={n: MotorCalibration(**v) for n, v in raw.items()})
    bus.connect(handshake=False)
    return bus


def cmd_capture(a):
    cap = cv2.VideoCapture(WRIST_CAM[a.arm], cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    bus = open_bus(a.arm)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 40, 0.001)
    views, prev_ang, still = [], None, 0.0
    t0 = time.time()
    print(f"mueve el brazo despacio; guardo poses distintas hasta {a.views} "
          f"o {a.seconds} s", flush=True)
    try:
        while len(views) < a.views and time.time() - t0 < a.seconds:
            ok, frame = cap.read()
            if not ok:
                continue
            ang = np.array([bus.read("Present_Position", j) for j in ARM])
            if prev_ang is not None:
                still = still + 0.05 if np.abs(ang - prev_ang).max() < 0.6 else 0.0
            prev_ang = ang
            if still < a.settle:
                continue
            g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            found, c = cv2.findChessboardCorners(
                g, (NX, NY),
                cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
            if not found:
                continue
            c = cv2.cornerSubPix(g, c, (11, 11), (-1, -1), crit)
            # una vista nueva tiene que diferenciarse en angulos: si no, es la
            # misma pose repetida y solo aporta ruido al ajuste.
            if any(np.abs(ang - v["ang"]).max() < a.min_sep for v in views):
                continue
            views.append({"ang": ang, "corners": c.reshape(-1, 2)})
            still = 0.0
            print(f"   vista {len(views):2d}/{a.views}  angulos "
                  + " ".join(f"{v:7.1f}" for v in ang[:3]), flush=True)
    finally:
        cap.release()
        # NOT a bare disconnect(): lerobot's default writes Torque_Enable=0
        # to every motor, which would drop a held arm.
        bus.disconnect(disable_torque=False)

    if len(views) < 8:
        print(f"FALLO: solo {len(views)} vistas, hacen falta 8 como minimo")
        return 1
    np.savez(a.out,
             ang=np.array([v["ang"] for v in views]),
             corners=np.array([v["corners"] for v in views]),
             size=np.array([a.width, a.height]))
    print(f"\n{len(views)} vistas guardadas en {a.out}")
    return 0


def _mover(bus, cur, tgt, paso=2.0, settle=0.05):
    """Interpola en pasos de <=2 grados: un salto directo tira del brazo."""
    import numpy as _np
    n = max(1, int(_np.abs(_np.array([tgt[j] - cur[j] for j in ARM])).max() / paso))
    for k in range(1, n + 1):
        bus.sync_write("Goal_Position",
                       {j: cur[j] + (tgt[j] - cur[j]) * k / n for j in ARM})
        time.sleep(settle)
    time.sleep(0.35)


def cmd_auto(a):
    """Captura sin manos: el brazo recorre variaciones de la pose de partida.

    La pose de partida la coloca una persona, y tiene que ser una en la que la
    camara ya vea el tablero entero: asi la exploracion arranca de un sitio
    seguro y conocido, y los desvios se quedan pequenos. Cada desvio se prueba,
    se mira si el tablero sigue completo, y solo entonces se guarda.
    """
    cap = cv2.VideoCapture(WRIST_CAM[a.arm], cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    bus = open_bus(a.arm)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 40, 0.001)

    def ver():
        for _ in range(6):
            ok, f = cap.read()
        if not ok:
            return None
        g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
        found, c = cv2.findChessboardCorners(
            g, (NX, NY),
            cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
        return cv2.cornerSubPix(g, c, (11, 11), (-1, -1), crit) if found else None

    # Fijar el par ANTES de comprobar nada: con el par suelto el brazo se vence
    # en cuanto la persona lo deja, y para cuando se mira la camara la pose de
    # partida ya se ha perdido.
    seed = {j: float(bus.read("Present_Position", j)) for j in ARM}
    for j in ARM:
        bus.write("Torque_Limit", j, a.torque, normalize=False)
    bus.sync_write("Goal_Position", seed)      # objetivo = donde esta, sin tiron
    for j in ARM:
        bus.write("Torque_Enable", j, 1)
    print("pose sujeta por los servos; compruebo el tablero", flush=True)
    if ver() is None:
        print("FALLO: desde la pose de partida no se ve el tablero entero")
        for j in ARM:
            bus.write("Torque_Enable", j, 0)
        cap.release(); bus.disconnect(disable_torque=False)
        return 1
    print("pose de partida buena; empiezo el recorrido", flush=True)

    D = a.amplitud
    desvios = [{}]
    for j, k in (("shoulder_pan", 1.0), ("shoulder_lift", 0.7),
                 ("elbow_flex", 1.0), ("wrist_flex", 1.3), ("wrist_roll", 1.6)):
        for s_ in (+1, -1):
            desvios.append({j: s_ * D * k})
    for s1 in (+1, -1):
        for s2 in (+1, -1):
            desvios.append({"shoulder_pan": s1 * D, "wrist_roll": s2 * D * 1.6})
            desvios.append({"elbow_flex": s1 * D, "wrist_flex": s2 * D * 1.3})
            desvios.append({"shoulder_lift": s1 * D * 0.7, "wrist_flex": s2 * D})

    views, fallos = [], 0
    try:
        cur = dict(seed)
        for i, dd in enumerate(desvios):
            if len(views) >= a.views:
                break
            tgt = {j: seed[j] + dd.get(j, 0.0) for j in ARM}
            _mover(bus, cur, tgt); cur = tgt
            real = np.array([bus.read("Present_Position", j) for j in ARM])
            c = ver()
            if c is None:
                fallos += 1
                print(f"   {i+1:2d}/{len(desvios)}  tablero fuera de cuadro", flush=True)
                continue
            views.append({"ang": real, "corners": c.reshape(-1, 2)})
            print(f"   {i+1:2d}/{len(desvios)}  vista {len(views)} guardada", flush=True)
        _mover(bus, cur, seed)
    finally:
        for j in ARM:
            bus.write("Torque_Enable", j, 0)
        cap.release()
        # NOT a bare disconnect(): lerobot's default writes Torque_Enable=0
        # to every motor, which would drop a held arm.
        bus.disconnect(disable_torque=False)

    print(f"\n{len(views)} vistas, {fallos} desvios descartados por perder el tablero")
    if len(views) < 8:
        print("FALLO: hacen falta 8 como minimo")
        return 1
    np.savez(a.out,
             ang=np.array([v["ang"] for v in views]),
             corners=np.array([v["corners"] for v in views]),
             size=np.array([a.width, a.height]))
    print(f"guardadas en {a.out}")
    return 0


def cmd_solve(a):
    from lerobot.model.kinematics import RobotKinematics
    d = np.load(a.views_file)
    ang, corners = d["ang"], d["corners"]
    w, h = (int(v) for v in d["size"])
    n = len(ang)
    op = objp()

    rms, K, dist, _, _ = cv2.calibrateCamera(
        [op] * n, [c.reshape(-1, 1, 2).astype(np.float32) for c in corners],
        (w, h), None, None)
    print(f"intrinsecos de la muneca: RMS {rms:.3f} px   "
          f"fx {K[0,0]:.1f} fy {K[1,1]:.1f}   {n} vistas")

    R_t2c, t_t2c = [], []
    for c in corners:
        ok, rv, tv = cv2.solvePnP(op, c.reshape(-1, 1, 2), K, dist)
        R_t2c.append(cv2.Rodrigues(rv)[0])
        t_t2c.append(tv)

    kin = RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],
                          target_frame_name="gripper_frame_link",
                          joint_names=ARM)
    T_bg = []
    for q in ang:
        T = kin.forward_kinematics(np.asarray(q)).copy()
        T[:3, 3] *= 1000.0
        T_bg.append(T)
    # calibrateRobotWorldHandEye quiere base->pinza, o sea la inversa de la FK
    R_b2g = [np.linalg.inv(T)[:3, :3] for T in T_bg]
    t_b2g = [np.linalg.inv(T)[:3, 3] for T in T_bg]

    R_b2t, t_b2t, R_g2c, t_g2c = cv2.calibrateRobotWorldHandEye(
        R_t2c, t_t2c, R_b2g, t_b2g)

    X = np.eye(4); X[:3, :3] = R_g2c; X[:3, 3] = t_g2c.ravel()
    # T_brazo_tablero deberia salir igual desde cada vista; su dispersion es la
    # validacion honesta, no el residuo interno del solver.
    est = []
    for T, R, t in zip(T_bg, R_t2c, t_t2c):
        Tct = np.eye(4); Tct[:3, :3] = R; Tct[:3, 3] = t.ravel()
        est.append(T @ X @ Tct)
    pos = np.array([e[:3, 3] for e in est])
    disp = np.linalg.norm(pos - pos.mean(0), axis=1)
    print(f"\ntablero en el marco del brazo, visto desde cada pose:")
    print(f"   media   ({pos.mean(0)[0]:7.1f},{pos.mean(0)[1]:7.1f},{pos.mean(0)[2]:7.1f}) mm")
    print(f"   dispersion  media {disp.mean():.2f} mm   maxima {disp.max():.2f} mm")
    print(f"\ncamara de muneca en el marco de la pinza: "
          f"({t_g2c.ravel()[0]:.1f},{t_g2c.ravel()[1]:.1f},{t_g2c.ravel()[2]:.1f}) mm")

    Path(a.out).write_text(json.dumps({
        "_nota": "Mano-ojo con la camara de muneca. La punta no interviene.",
        "vistas": n,
        "intrinsecos_muneca": {"rms_px": rms, "K": K.tolist(),
                               "dist": dist.ravel().tolist(),
                               "width": w, "height": h},
        "camara_en_pinza_mm": t_g2c.ravel().tolist(),
        "R_camara_en_pinza": R_g2c.tolist(),
        "tablero_en_brazo_mm": pos.mean(0).tolist(),
        "dispersion_media_mm": float(disp.mean()),
        "dispersion_max_mm": float(disp.max()),
    }, indent=2))
    print(f"\nescrito en {a.out}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="cmd", required=True)
    c = s.add_parser("capture")
    c.add_argument("--arm", choices=PORTS, default="right")
    c.add_argument("--views", type=int, default=18)
    c.add_argument("--seconds", type=int, default=600)
    c.add_argument("--settle", type=float, default=0.4,
                   help="segundos quieto antes de aceptar una vista")
    c.add_argument("--min-sep", type=float, default=6.0,
                   help="grados minimos de diferencia con las vistas ya guardadas")
    c.add_argument("--width", type=int, default=1280)
    c.add_argument("--height", type=int, default=720)
    c.add_argument("--out", default="vistas_muneca.npz")
    c.set_defaults(fn=cmd_capture)
    u = s.add_parser("auto", help="el brazo se mueve solo desde la pose de partida")
    u.add_argument("--arm", choices=PORTS, default="right")
    u.add_argument("--views", type=int, default=18)
    u.add_argument("--amplitud", type=float, default=7.0,
                   help="grados de desvio respecto a la pose de partida")
    u.add_argument("--torque", type=int, default=350)
    u.add_argument("--width", type=int, default=1280)
    u.add_argument("--height", type=int, default=720)
    u.add_argument("--out", default="vistas_muneca.npz")
    u.set_defaults(fn=cmd_auto)
    v = s.add_parser("solve")
    v.add_argument("--views-file", default="vistas_muneca.npz")
    v.add_argument("--out", default="calibration/handeye_right.json")
    v.set_defaults(fn=cmd_solve)
    a = p.parse_args()
    raise SystemExit(a.fn(a))


if __name__ == "__main__":
    main()
