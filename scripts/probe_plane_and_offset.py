#!/usr/bin/env python3
"""Resolver el plano de la mesa Y el desfase de la pinza A LA VEZ.

Medirlos por separado es circular, y esa circularidad contamino toda la cadena:
para saber donde esta el plano hay que saber que punto de la pinza lo toca, y
para saber cual es ese punto hay que conocer el plano. Sintoma medido: variando
el CODO, la z de contacto cambiaba 9 mm de forma sistematica (-0.036 con el codo
recogido, -0.027 estirado) mientras los giros de pan a igual codo daban z
identica. Eso no es la mesa inclinandose: es el desfase rotando con la
orientacion. De ahi tres "inclinaciones de la mesa" incompatibles entre si
(2.4, 4.3 y 7.9 grados) segun como se repartieran los contactos.

Cada contacto cumple  n . (R_i @ o + p_i) = d  con n unitaria. Incognitas: la
normal (2 gdl), la altura d (1) y el desfase o (3). Con contactos en
orientaciones variadas el sistema se separa; si no se varian, o.n y d son
inseparables -- por eso se mide el condicionamiento y se rechaza si no da.

  python scripts/probe_plane_and_offset.py --out calibration/plane_offset.json
"""
import argparse
import json
import os
import pathlib
import sys
import time

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from contact_probe import LimitePar  # noqa: E402

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll",
       "gripper"]
PASO = 12
MAX_PASOS = 110
SALTO_MIN = 200
TEMP_MAX = 50


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", default="/dev/cu.usbmodem5B610332201")
    p.add_argument("--id", default="xle_right")
    p.add_argument("--obs-out", default="",
                   help="guardar las observaciones CRUDAS (R y p de cada contacto). "
                        "Se escribe siempre, tambien si el ajuste se rechaza: sin "
                        "esto, reanalizar cuesta otros 10 minutos de robot.")
    p.add_argument("--max-sigma-mm", type=float, default=8.0,
                   help="incertidumbre maxima admisible del desfase. Se juzga por "
                        "esto y no por el numero de condicion, que es una cifra sin "
                        "unidades: lo que importa son los milimetros.")
    p.add_argument("--out", default="")
    a = p.parse_args()

    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.model.kinematics import RobotKinematics
    from scipy.optimize import least_squares

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

    def temp():
        return int(rob.bus.read("Present_Temperature", "shoulder_lift",
                                normalize=False))

    obs = []
    # Limitar el par durante TODO el protocolo parecia buena idea para el calor y
    # salio al reves: sostener el brazo necesita poco par, pero LEVANTARLO (cada
    # pose empieza devolviendolo arriba) necesita mas. Con el limite puesto no
    # llegaba, se quedaba cada vez mas bajo y mas girado -- 12 de 39 poses
    # descartadas por orientacion y 7 sin contacto -- y encima el servo forzaba
    # contra su propio limite en cada reposicionamiento, que es lo que acabo
    # disparando la proteccion termica. El limite va SOLO en el descenso.
    par = None          # se abre y cierra por descenso, no para todo el protocolo
    try:
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False)
        print("  limite de par SOLO durante el descenso", flush=True)
        ini = {j: int(rob.bus.read("Present_Position", j, normalize=False))
               for j in ARM}
        L = {j: (int(rob.bus.read("Min_Position_Limit", j, normalize=False)),
                 int(rob.bus.read("Max_Position_Limit", j, normalize=False)))
             for j in ARM}

        # Mas variedad de orientacion: con la muneca variada en solo 2 posiciones el
    # condicionamiento salio 505, o sea que el desfase y la altura del plano
    # apenas se separaban.
    # Hay que variar DOS cosas independientes: donde se toca (pan, codo) para
        # que el plano quede determinado, y como se toca (muneca) para separar el
        # desfase de la altura del plano. Variar solo una de las dos deja el
        # sistema indeterminado en la otra.
        confs = []
        for pan in (0, -180, +180, -320, +320):
            for codo in (0, -170, +170):
                confs.append((pan, codo, 0, 0))
        for wf, wr in ((-240, 0), (+240, 0), (0, -280), (0, +280), (-170, +200),
                       (+170, -200), (-240, +280), (+240, -280)):
            confs.append((0, 0, wf, wr))
            confs.append((-180, -170, wf, wr))
            confs.append((+180, +170, wf, wr))

        for k, (pan, codo, wf, wr) in enumerate(confs):
            if temp() > TEMP_MAX:
                print(f"  hombro a {temp()} C; espero", flush=True)
                while temp() > TEMP_MAX - 4:
                    time.sleep(10)
            for j in ARM:
                rob.bus.write("Goal_Position", j, ini[j], normalize=False)
            time.sleep(1.1)
            # Hombro, codo y muneca giran sobre ejes PARALELOS en este brazo, asi
            # que la inclinacion de la pinza es la suma de los tres. Mover el codo
            # sin compensar la muneca cambia el angulo con que la pinza llega a la
            # mesa, o sea que TOCA CON OTRA PARTE -- y el modelo supone un unico
            # punto rigido. Compensando, el angulo de llegada se conserva y solo
            # cambia DONDE se toca; la variedad de orientacion se introduce luego
            # a proposito, con wf/wr, que es lo que hace observable el desfase.
            # Ratio EXACTO segun la cinematica, no 1:1 a ojo: 170 ticks de codo
            # giran la pinza 15.34 grados y 170 de muneca 14.72, asi que hacen
            # falta 177 de muneca por cada 170 de codo. (El 4% que faltaba no
            # explicaba los descartes de 8 grados; la causa era el limite de par.)
            comp = int(round(-codo * 15.34 / 14.72)) if codo else 0
            for j, dv in (("shoulder_pan", pan), ("elbow_flex", codo),
                          ("wrist_flex", wf + comp), ("wrist_roll", wr)):
                if dv:
                    rob.bus.write("Goal_Position", j,
                                  int(np.clip(ini[j] + dv, L[j][0] + 30,
                                              L[j][1] - 30)), normalize=False)
            time.sleep(1.4)
            # y COMPROBAR que la compensacion funciono, en vez de confiarla
            Tv = pose()
            if k == 0:
                orient0 = Tv[:3, :3].copy()
            elif wf == 0 and wr == 0:
                da = np.degrees(np.arccos(np.clip(
                    (np.trace(orient0.T @ Tv[:3, :3]) - 1) / 2, -1, 1)))
                if da > 8:
                    print(f"  {k+1}/{len(confs)}: la pinza quedo {da:.0f} grados "
                          "girada pese a compensar; descarto esta pose", flush=True)
                    continue
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
            hist, T = [], None
            for _ in range(MAX_PASOS):
                lift = int(np.clip(lift + sgn * PASO, L["shoulder_lift"][0] + 30,
                                   L["shoulder_lift"][1] - 30))
                rob.bus.write("Goal_Position", "shoulder_lift", lift,
                              normalize=False)
                time.sleep(0.3)
                c = carga()
                hist.append(c)
                salto = c - min(hist[-4:-1]) if len(hist) >= 4 else 0.0
                if c > base + 150 and salto > SALTO_MIN:
                    T = pose()
                    rob.bus.write("Goal_Position", "shoulder_lift",
                                  int(np.clip(lift - sgn * 3 * PASO,
                                              L["shoulder_lift"][0] + 30,
                                              L["shoulder_lift"][1] - 30)),
                                  normalize=False)
                    break
                if lift in (L["shoulder_lift"][0] + 30, L["shoulder_lift"][1] - 30):
                    break
            if T is None:
                print(f"  {k+1}/{len(confs)}: sin contacto", flush=True)
            else:
                obs.append((T[:3, :3].tolist(), T[:3, 3].tolist()))
                print(f"  {k+1}/{len(confs)} (pan {pan:+4d} codo {codo:+4d} "
                      f"flex {wf:+4d} roll {wr:+4d}): contacto en "
                      f"({T[0,3]:+.3f},{T[1,3]:+.3f},{T[2,3]:+.3f})", flush=True)
            rob.bus.write("Goal_Position", "shoulder_lift",
                          int(np.clip(lift - sgn * 110, L["shoulder_lift"][0] + 30,
                                      L["shoulder_lift"][1] - 30)), normalize=False)
            time.sleep(1.1)
            # Pausa real entre poses: el hombro es el que calienta, y 39 poses
            # seguidas lo llevaron a proteccion termica tres veces.
            if (k + 1) % 8 == 0 and temp() > 46:
                print(f"    pausa: hombro a {temp()} C", flush=True)
                while temp() > 43:
                    time.sleep(15)
        for j in ARM:
            rob.bus.write("Goal_Position", j, ini[j], normalize=False)
        time.sleep(1.2)
    finally:
        if par is not None:
            par.__exit__(None, None, None)
        try:
            rob.bus.disconnect(disable_torque=False)
        except Exception:
            pass

    if a.obs_out and obs:
        pathlib.Path(a.obs_out).write_text(json.dumps(
            {"obs": [{"R": o[0], "p": o[1]} for o in obs]}, indent=2) + "\n")
        print(f"\n  observaciones crudas -> {a.obs_out} ({len(obs)} contactos)")
    if len(obs) < 8:
        sys.exit(f"\nsolo {len(obs)} contactos; hacen falta bastantes mas que 6 "
                 "incognitas")
    R = np.array([o[0] for o in obs])
    P = np.array([o[1] for o in obs])

    def desempaqueta(q):
        # normal por dos angulos: se mantiene unitaria sin restricciones extra
        th, ph, dd = q[0], q[1], q[2]
        n = np.array([np.sin(th) * np.cos(ph), np.sin(th) * np.sin(ph), np.cos(th)])
        return n, dd, q[3:6]

    def resid(q):
        n, dd, o = desempaqueta(q)
        pc = np.einsum("ijk,k->ij", R, o) + P
        return pc @ n - dd

    q0 = np.array([0.0, 0.0, float(P[:, 2].mean()), 0.0, 0.0, 0.0])
    sol = least_squares(resid, q0, method="trf", max_nfev=40000)
    n, dd, o = desempaqueta(sol.x)
    if n[2] < 0:
        n, dd = -n, -dd
    r = resid(sol.x)

    # Condicionamiento: si las orientaciones no varian, o.n y d son inseparables
    J = sol.jac
    s = np.linalg.svd(J, compute_uv=False)
    cond = float(s[0] / s[-1]) if s[-1] > 1e-12 else float("inf")
    tilt = float(np.degrees(np.arccos(np.clip(abs(n[2]), -1, 1))))
    print(f"\n  {len(obs)} contactos, {len(obs)*1} ecuaciones, 6 incognitas")
    print(f"  condicionamiento {cond:.0f}")
    print(f"  PLANO  normal ({n[0]:+.3f},{n[1]:+.3f},{n[2]:+.3f}) -> {tilt:.1f} grados"
          f", altura d={dd:+.4f} m")
    print(f"  DESFASE ({o[0]*100:+.1f},{o[1]*100:+.1f},{o[2]*100:+.1f}) cm  "
          f"|{np.linalg.norm(o)*100:.1f}| cm")
    print(f"  residuos: max {np.abs(r).max()*1000:.1f} mm, "
          f"rms {np.sqrt((r**2).mean())*1000:.1f} mm")
    # El numero de condicion no dice cuanto se equivoca uno; la covarianza si.
    # Se propaga el ruido de los residuos a los parametros y se juzga en mm.
    gl = max(len(r) - 6, 1)
    s2 = float((r ** 2).sum()) / gl
    try:
        cov = s2 * np.linalg.pinv(J.T @ J)
        sig = np.sqrt(np.clip(np.diag(cov), 0, None))
        sig_off = sig[3:6] * 1000
        sig_d = sig[2] * 1000
        print(f"  incertidumbre: desfase +-({sig_off[0]:.1f},{sig_off[1]:.1f},"
              f"{sig_off[2]:.1f}) mm, altura del plano +-{sig_d:.1f} mm")
    except Exception:
        sig_off = np.array([99.0, 99.0, 99.0])
        print("  no pude estimar la incertidumbre")
    if sig_off.max() > a.max_sigma_mm:
        print(f"\n  DEMASIADA INCERTIDUMBRE: {sig_off.max():.1f} mm en el desfase "
              f"(maximo {a.max_sigma_mm:.0f}). Falta variedad de orientacion para "
              "separarlo de la altura del plano. No escribo nada.")
        return 1
    if np.abs(r).max() > 0.005:
        print("\n  residuos altos: el punto que toca no es siempre el mismo, o la "
              "mesa no es plana. No escribo nada.")
        return 1
    if a.out:
        pathlib.Path(a.out).write_text(json.dumps(
            {"normal": [round(float(v), 6) for v in n], "d_m": round(float(dd), 5),
             "contact_offset_m": [round(float(v), 5) for v in o],
             "contacts": len(obs), "condition": round(cond, 1),
             "tilt_deg": round(tilt, 2),
             "max_residual_mm": round(float(np.abs(r).max() * 1000), 2),
             "rms_residual_mm": round(float(np.sqrt((r ** 2).mean()) * 1000), 2),
             "sigma_offset_mm": [round(float(v), 2) for v in sig_off],
             "method": "plano y desfase resueltos A LA VEZ sobre contactos con "
                       "posicion Y orientacion variadas. Medirlos por separado es "
                       "circular."}, indent=2) + "\n")
        print(f"\n  -> escrito {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
