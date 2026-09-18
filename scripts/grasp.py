#!/usr/bin/env python3
"""Agarrar: alinear con la camara de muneca, bajar, cerrar y comprobar.

El alineamiento lo hace wrist_servo (ojo en mano): la pegatina rosa marca donde
esta la punta en la imagen, y se mueve el brazo hasta que el objeto cae sobre
ella. Eso no necesita el desfase de la pinza, ni los extrinsecos de la torre, ni
el plano -- las tres cosas que no salieron.

Aqui se anade lo que falta, que es vertical y por tanto SI usa lo unico que se
pudo determinar del desfase: su componente z (+3.5 cm, +-3 mm).

La comprobacion del agarre mira la POSICION FINAL de la pinza, no la carga: si
se cierra del todo no cogio nada; si se detiene antes, hay algo dentro. Es una
medida directa y no una inferencia, que en esta sesion ha demostrado ser la
diferencia entre saber y suponer.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

import numpy as np

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll",
       "gripper"]


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--objetivo", nargs=2, type=float, required=True,
                   metavar=("U", "V"), help="pixel del objeto en la muneca")
    p.add_argument("--port", default="/dev/cu.usbmodem5B610332201")
    p.add_argument("--id", default="xle_right")
    p.add_argument("--altura-cierre", type=float, default=0.012,
                   help="altura de la punta sobre la mesa al cerrar (m)")
    p.add_argument("--sin-alinear", action="store_true",
                   help="saltar el alineamiento (usar si ya esta encima)")
    a = p.parse_args()

    aqui = pathlib.Path(__file__).resolve().parent
    if not a.sin_alinear:
        print("== 1. alinear ==", flush=True)
        r = subprocess.run([sys.executable, str(aqui / "wrist_servo.py"),
                            "--objetivo", str(a.objetivo[0]), str(a.objetivo[1]),
                            "--iteraciones", "12"], text=True)
        # Si el alineamiento FALLA, no hay nada que agarrar donde se cree. Antes
        # se imprimia el codigo y se seguia igual: un error de bus tumbo el
        # alineamiento y la secuencia bajo y cerro de todas formas.
        if r.returncode != 0:
            print(f"   el alineamiento fallo (codigo {r.returncode}); no sigo",
                  flush=True)
            return 1
        print("   alineado", flush=True)

    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.model.kinematics import RobotKinematics
    sys.path.insert(0, str(aqui))
    from contact_probe import Termostato

    plano = json.loads((aqui.parent / "calibration/table_plane_touch.json").read_text())
    n_pl = np.array(plano["normal"], np.float64)
    c_pl = np.array(plano["centroid"], np.float64)
    parcial = json.loads(
        (aqui.parent / "calibration/tool_offset_left_partial.json").read_text())
    dz = float(parcial["z_m"])

    kin = RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],
                          joint_names=ARM, target_frame_name="gripper_frame_link")
    rob = SO101Follower(SO101FollowerConfig(port=a.port, id=a.id))
    rob.bus.connect()
    termo = Termostato(rob.bus, blando=48, duro=50, reanudar=45)

    def altura():
        deg = rob.bus.sync_read("Present_Position", num_retry=3)
        T = np.asarray(kin.forward_kinematics(
            np.array([float(deg[j]) for j in ARM])), np.float64)
        return float((T[:3, 3] - c_pl) @ n_pl) - dz

    try:
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False)
        g_lo = int(rob.bus.read("Min_Position_Limit", "gripper", normalize=False))
        g_hi = int(rob.bus.read("Max_Position_Limit", "gripper", normalize=False))
        lo_l = int(rob.bus.read("Min_Position_Limit", "shoulder_lift",
                                normalize=False))
        hi_l = int(rob.bus.read("Max_Position_Limit", "shoulder_lift",
                                normalize=False))

        print("== 2. abrir la pinza ==", flush=True)
        rob.bus.write("Goal_Position", "gripper", g_hi - 40, normalize=False)
        time.sleep(1.5)

        print(f"== 3. bajar a {a.altura_cierre*100:.1f} cm, REALINEANDO por el "
              "camino ==", flush=True)
        # Bajar con el hombro tambien desplaza horizontalmente, asi que alinear
        # y LUEGO bajar pierde el alineamiento: la primera prueba cerro la pinza
        # donde el objeto ya no estaba. Hay que intercalar, no secuenciar.
        import cv2
        from wrist_servo import encuentra_rosa, encuentra_azul
        cap = cv2.VideoCapture(int(os.environ.get("LEX_XLE_CAMERA_LEFT_INDEX", "1")))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        for _ in range(8):
            cap.read()

        def error_px(cerca):
            for _ in range(4):
                cap.read()
            ok, f = cap.read()
            if not ok:
                return None, cerca
            ro, _m = encuentra_azul(f, cerca_de=cerca, salto_max=110)
            rr, _m2 = encuentra_rosa(f)
            if ro is None or rr is None:
                return None, cerca
            return ro[0] - rr[0], ro[0]
        lift = int(rob.bus.read("Present_Position", "shoulder_lift",
                                normalize=False))
        h0 = altura()
        rob.bus.write("Goal_Position", "shoulder_lift",
                      int(np.clip(lift + 25, lo_l + 30, hi_l - 30)), normalize=False)
        time.sleep(0.8)
        sgn = -1 if altura() > h0 else +1       # sentido que BAJA
        rob.bus.write("Goal_Position", "shoulder_lift", lift, normalize=False)
        time.sleep(0.8)
        # Bajar POR FASES, realineando entre ellas con el lazo completo. La
        # correccion casera que habia aqui movia el codo 8 ticks, que con su
        # jacobiano (-19 px/100 ticks) son 1.5 px, mientras el propio descenso
        # movia el hombro 18 ticks = ~4 px: la correccion era TRES VECES mas
        # debil que la perturbacion que intentaba compensar, y el error crecia de
        # 45 a 84 px mientras bajaba. Improvisar un controlador teniendo uno que
        # funciona fue el error; esto reutiliza el probado.
        h_ini = altura()
        fases = 3
        abortado = False
        for fase in range(fases):
            objetivo_h = h_ini + (a.altura_cierre - h_ini) * (fase + 1) / fases
            print(f"   fase {fase+1}/{fases}: bajar a {objetivo_h*100:+.1f} cm",
                  flush=True)
            for _ in range(30):
                if not termo.comprobar():
                    abortado = True
                    break
                h = altura()
                if h < objetivo_h - 0.006:
                    for _ in range(20):
                        if altura() >= objetivo_h:
                            break
                        lift = int(np.clip(lift - sgn * 8, lo_l + 30, hi_l - 30))
                        rob.bus.write("Goal_Position", "shoulder_lift", lift,
                                      normalize=False)
                        time.sleep(0.3)
                    break
                if abs(h - objetivo_h) <= 0.006:
                    break
                paso = 16 if (h - objetivo_h) > 0.02 else 7
                lift = int(np.clip(lift + sgn * paso, lo_l + 30, hi_l - 30))
                rob.bus.write("Goal_Position", "shoulder_lift", lift,
                              normalize=False)
                time.sleep(0.30)
            if abortado:
                break
            e, cerca = error_px(cerca)
            print(f"     a {altura()*100:+.1f} cm, error "
                  f"{'%.0f px' % np.linalg.norm(e) if e is not None else '?'}",
                  flush=True)
            if fase < fases - 1 and e is not None and np.linalg.norm(e) > 25:
                cap.release()
                r2 = subprocess.run(
                    [sys.executable, str(aqui / "wrist_servo.py"),
                     "--objetivo", str(cerca[0]), str(cerca[1]),
                     "--iteraciones", "5"], text=True, capture_output=True)
                for ln in r2.stdout.splitlines():
                    if ": objeto en" in ln or "LLEGADA" in ln:
                        print("     " + ln.strip(), flush=True)
                cap = cv2.VideoCapture(
                    int(os.environ.get("LEX_XLE_CAMERA_LEFT_INDEX", "1")))
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
                for _ in range(8):
                    cap.read()
                lift = int(rob.bus.read("Present_Position", "shoulder_lift",
                                        normalize=False))
                e, cerca = error_px(cerca)
        e, cerca = error_px(cerca)
        print(f"   punta a {altura()*100:+.1f} cm; error final "
              f"{'%.0f px' % np.linalg.norm(e) if e is not None else 'no medido'}",
              flush=True)
        cap.release()
        h_fin = altura()
        # Comprobar las DOS direcciones. La guarda solo miraba "no bajo lo
        # suficiente", y el descenso se paso a -2.3 cm -- por DEBAJO de la mesa,
        # presionando contra ella. Quedarse corto es un intento fallido;
        # pasarse es empujar el brazo contra el tablero.
        if abortado or not (a.altura_cierre - 0.010 < h_fin < a.altura_cierre + 0.020):
            print(f"\n   NO CIERRO: la punta quedo a {h_fin*100:+.1f} cm y se "
                  f"esperaba {a.altura_cierre*100:.1f}"
                  + (" (abortado por temperatura)" if abortado else ""), flush=True)
            if h_fin < a.altura_cierre:
                print("   LEVANTO para no seguir presionando", flush=True)
                for _ in range(12):
                    lift = int(np.clip(lift - sgn * 20, lo_l + 30, hi_l - 30))
                    rob.bus.write("Goal_Position", "shoulder_lift", lift,
                                  normalize=False)
                    time.sleep(0.3)
                    if altura() > 0.06:
                        break
            return 1
        print("== 4. cerrar ==", flush=True)
        rob.bus.write("Goal_Position", "gripper", g_lo + 20, normalize=False)
        time.sleep(2.2)
        cerrado = int(rob.bus.read("Present_Position", "gripper", normalize=False))
        carga = int(rob.bus.read("Present_Load", "gripper", normalize=False)) & 0x3FF
        margen = cerrado - (g_lo + 20)
        print(f"   la pinza quedo en {cerrado} (tope {g_lo+20}), o sea {margen} "
              f"ticks sin cerrar; carga {carga}", flush=True)
        # Un objeto impide cerrar del todo. Sin objeto, llega al tope.
        hay_algo = margen > 60
        print(f"   -> {'HAY ALGO DENTRO' if hay_algo else 'NO cogio nada (cerro del todo)'}",
              flush=True)

        print("== 5. levantar ==", flush=True)
        for _ in range(18):
            lift = int(np.clip(lift - sgn * 20, lo_l + 30, hi_l - 30))
            rob.bus.write("Goal_Position", "shoulder_lift", lift, normalize=False)
            time.sleep(0.3)
            if altura() > 0.08:
                break
        print(f"   punta a {altura()*100:+.1f} cm", flush=True)
        tras = int(rob.bus.read("Present_Position", "gripper", normalize=False))
        print(f"   la pinza sigue en {tras} ({tras-cerrado:+d} desde el cierre)",
              flush=True)
        if hay_algo and abs(tras - cerrado) < 40:
            print("\n   AGARRE CONSEGUIDO: cerro sobre algo y lo mantiene al subir",
                  flush=True)
        elif hay_algo:
            print("\n   se solto al levantar", flush=True)
        else:
            print("\n   sin agarre", flush=True)
    finally:
        # SOLTAR AL SALIR. Terminar con el par puesto deja el brazo sosteniendose
        # y calentando sin hacer nada: tras un intento quedo con carga 276 en el
        # hombro y 51 C. El agarre ya termino; lo que hay que preservar es el
        # objeto en la pinza, y eso solo aplica si de verdad cogio algo.
        try:
            for j in ARM:
                if j == "gripper" and locals().get("hay_algo"):
                    continue          # si sostiene algo, la pinza sigue apretando
                rob.bus.write("Torque_Enable", j, 0, normalize=False)
        except Exception:
            pass
        try:
            rob.bus.disconnect(disable_torque=False)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
