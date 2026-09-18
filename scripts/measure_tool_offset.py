#!/usr/bin/env python3
"""Medir DONDE estan los dedos respecto a gripper_frame_link. Sin camara.

El desfase es un vector FIJO en el marco de la pinza, asi que al girar la muneca
rota con ella. Si se toca la mesa con orientaciones distintas, el punto de
contacto se queda en el plano pero el origen del marco no: cada contacto da

    n . (R_pinza @ desfase + p_pinza) = d

que es LINEAL en el desfase. Con 3 orientaciones independientes queda
determinado, y con mas se ajusta por minimos cuadrados.

Esto importa porque el desfase no es un estorbo: cerrar la pinza alrededor de un
objeto exige saber donde estan los dedos. Estimarlo DENTRO del ajuste de
extrinsecos no funciona -- ahi se confunde con la pose de la camara y se topa
contra sus limites (salio ~13 cm, del mismo orden que el error de punteria).
Aqui no interviene la camara, asi que no hay nada con que confundirlo.

  python scripts/measure_tool_offset.py --plane calibration/table_plane_touch.json
"""
import argparse
import json
import os
import pathlib
import sys
import time

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from contact_probe import LimitePar, bajar_hasta_tocar  # noqa: E402

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll",
       "gripper"]
PASO = 14                # paso normal, lejos del contacto
PASO_FINO = 5            # al notar que la carga empieza a subir
MAX_PASOS = 110
SALTO_MIN = 120          # un contacto real salta ~950; la gravedad sube poco a poco
SUBIR_TRAS = 110
TEMP_MAX = 48            # grados: por encima, se descansa antes de seguir


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--plane", required=True, help="plano de la mesa medido por tacto")
    p.add_argument("--port", default="/dev/cu.usbmodem5B610332201")
    p.add_argument("--id", default="xle_right")
    p.add_argument("--out", default="")
    a = p.parse_args()

    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.model.kinematics import RobotKinematics

    pl = json.loads(pathlib.Path(a.plane).read_text())
    n = np.array(pl["normal"], np.float64)
    d = float(np.array(pl["centroid"], np.float64) @ n)

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM,
                          target_frame_name="gripper_frame_link")
    rob = SO101Follower(SO101FollowerConfig(port=a.port, id=a.id))
    rob.bus.connect()

    def pose():
        deg = rob.bus.sync_read("Present_Position", num_retry=3)
        return np.asarray(kin.forward_kinematics(
            np.array([float(deg[j]) for j in ARM])), np.float64)

    def carga():
        return float(max(int(rob.bus.read("Present_Load", j, normalize=False)) & 0x3FF
                         for j in ("shoulder_lift", "elbow_flex")))

    def temp(j):
        return int(rob.bus.read("Present_Temperature", j, normalize=False))

    def lim(j):
        return (int(rob.bus.read("Min_Position_Limit", j, normalize=False)),
                int(rob.bus.read("Max_Position_Limit", j, normalize=False)))

    try:
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False)
        inicio = {j: int(rob.bus.read("Present_Position", j, normalize=False))
                  for j in ARM}
        L = {j: lim(j) for j in ARM}
        T0 = pose()
        print(f"  pinza en ({T0[0,3]:+.3f},{T0[1,3]:+.3f},{T0[2,3]:+.3f}) m, "
              f"a {(T0[:3,3] @ n - d)*100:+.1f} cm del plano", flush=True)

        # Orientaciones distintas de muneca: es lo que hace observable el desfase.
        # Sin variarlas, el termino R@desfase es casi constante y el ajuste queda
        # indeterminado -- exactamente lo que le pasaba dentro de los extrinsecos.
        confs = [(0, 0), (-220, 0), (+220, 0), (0, -260), (0, +260), (-150, +180)]
        obs = []
        for k, (dflex, droll) in enumerate(confs):
            for j in ARM:
                rob.bus.write("Goal_Position", j, inicio[j], normalize=False)
            time.sleep(1.2)
            for j, dv in (("wrist_flex", dflex), ("wrist_roll", droll)):
                rob.bus.write("Goal_Position", j,
                              int(np.clip(inicio[j] + dv, L[j][0] + 30, L[j][1] - 30)),
                              normalize=False)
            time.sleep(1.4)
            base = max(carga() for _ in range(4))
            lift = int(rob.bus.read("Present_Position", "shoulder_lift",
                                    normalize=False))
            z0 = pose()[2, 3]
            rob.bus.write("Goal_Position", "shoulder_lift",
                          int(np.clip(lift + 30, L["shoulder_lift"][0] + 30,
                                      L["shoulder_lift"][1] - 30)), normalize=False)
            time.sleep(0.8)
            sgn = +1 if pose()[2, 3] < z0 else -1
            rob.bus.write("Goal_Position", "shoulder_lift", lift, normalize=False)
            time.sleep(0.8)
            # Detectar el contacto obliga a EMPUJAR hasta que la carga sube, y
            # repetirlo sobrecalento el servo del hombro hasta su enclavamiento
            # de sobrecarga (51 C contra 39 de los demas). Tres cambios: pasos
            # finos en cuanto la carga empieza a moverse, umbral de salto mas
            # bajo, y retirada INMEDIATA al tocar en vez de completar el paso.
            t_ini = temp("shoulder_lift")
            if t_ini > TEMP_MAX:
                print(f"  conf {k+1}: hombro a {t_ini} C (max {TEMP_MAX}); "
                      "espero a que enfrie", flush=True)
                while temp("shoulder_lift") > TEMP_MAX - 3:
                    time.sleep(10)
                print(f"    enfriado a {temp('shoulder_lift')} C", flush=True)
            lift = int(rob.bus.read("Present_Position", "shoulder_lift",
                                    normalize=False))
            z0 = pose()[2, 3]
            rob.bus.write("Goal_Position", "shoulder_lift",
                          int(np.clip(lift + 30, L["shoulder_lift"][0] + 30,
                                      L["shoulder_lift"][1] - 30)), normalize=False)
            time.sleep(0.8)
            sgn = +1 if pose()[2, 3] < z0 else -1
            rob.bus.write("Goal_Position", "shoulder_lift", lift, normalize=False)
            time.sleep(0.8)
            # Con el limite de par bajo, el servo se rinde en vez de forzar: el
            # contacto se nota porque no llega, no porque la carga suba. Es lo
            # que evita las dos sobrecargas que provoco la deteccion por carga.
            T = None
            with LimitePar(rob.bus, ("shoulder_lift", "elbow_flex")):
                if bajar_hasta_tocar(rob.bus, "shoulder_lift", sgn,
                                     L["shoulder_lift"]):
                    T = pose()
            if T is None:
                print(f"  conf {k+1}: sin contacto", flush=True)
            else:
                obs.append((T[:3, :3].copy(), T[:3, 3].copy()))
                print(f"  conf {k+1} (flex {dflex:+4d}, roll {droll:+4d}): contacto, "
                      f"origen del marco a {(T[:3,3] @ n - d)*100:+.1f} cm del plano, "
                      f"hombro a {temp('shoulder_lift')} C", flush=True)
            rob.bus.write("Goal_Position", "shoulder_lift",
                          int(np.clip(lift - sgn * SUBIR_TRAS,
                                      L["shoulder_lift"][0] + 30,
                                      L["shoulder_lift"][1] - 30)), normalize=False)
            time.sleep(1.2)
        for j in ARM:
            rob.bus.write("Goal_Position", j, inicio[j], normalize=False)
        time.sleep(1.2)
    finally:
        try:
            rob.bus.disconnect(disable_torque=False)
        except Exception:
            pass

    if len(obs) < 3:
        sys.exit(f"\nsolo {len(obs)} contactos; hacen falta 3 orientaciones distintas")
    A = np.array([n @ R for R, _ in obs])
    b = np.array([d - float(n @ p) for _, p in obs])
    # Sin variedad de orientacion las filas de A son casi iguales y el sistema
    # queda indeterminado: se mide antes de resolver, en vez de descubrirlo por
    # un resultado absurdo.
    s = np.linalg.svd(A, compute_uv=False)
    cond = float(s[0] / s[-1]) if s[-1] > 1e-12 else float("inf")
    print(f"\n  {len(obs)} contactos; condicionamiento del sistema {cond:.0f}")
    if cond > 200:
        print("  MAL CONDICIONADO: las orientaciones se parecen demasiado y el "
              "desfase no queda determinado. No escribo nada.")
        return 1
    off, *_ = np.linalg.lstsq(A, b, rcond=None)
    res = A @ off - b
    print(f"  DESFASE ({off[0]*100:+.1f},{off[1]*100:+.1f},{off[2]*100:+.1f}) cm  "
          f"|{np.linalg.norm(off)*100:.1f}| cm")
    print(f"  residuos: {' '.join(f'{v*1000:+.1f}' for v in res)} mm  "
          f"(max {np.abs(res).max()*1000:.1f} mm)")
    if np.abs(res).max() > 0.008:
        print("  aviso: residuos altos -- el punto que toca no es siempre el mismo")
    if a.out:
        pathlib.Path(a.out).write_text(json.dumps(
            {"tool_offset_m": [round(float(v), 5) for v in off],
             "contacts": len(obs), "condition": round(cond, 1),
             "max_residual_mm": round(float(np.abs(res).max() * 1000), 2),
             "method": "contactos con la mesa en varias orientaciones de muneca; "
                       "sistema lineal n.(R@off+p)=d. Sin camara."},
            indent=2) + "\n")
        print(f"  -> escrito {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
