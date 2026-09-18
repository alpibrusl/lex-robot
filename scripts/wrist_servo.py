#!/usr/bin/env python3
"""Llevar la pinza sobre un objeto usando la camara de la MUNECA (ojo en mano).

Por que asi y no desde la torre: la pegatina rosa marca, EN LA IMAGEN DE LA
MUNECA, donde esta la punta de la pinza. Como camara y pegatina van montadas
ambas en la pinza, ese pixel es una CONSTANTE -- un punto de mira fijo. Basta
mover el brazo hasta que el objeto caiga sobre el.

Eso elimina todo lo que se resistio durante la calibracion:
  - el desfase de la pinza: no se calcula, la pegatina lo ENSENA
  - los extrinsecos de la torre: no intervienen
  - el plano de la mesa: no interviene
  - la deteccion de la pinza por diferencia de movimiento: no hace falta, y era
    lo que fallaba (la sombra sobre madera y la malla del carro tenian mas
    contraste que la pinza negra, asi que el centroide se iba a otro sitio)

Objeto y punto de mira estan en la MISMA imagen, asi que un error de calibracion
los desplaza a los dos por igual y se cancela. No hay cadena de transformaciones
que pueda desalinearse porque no hay cadena.
"""
import argparse
import json
import os
import pathlib
import sys
import time

import numpy as np

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll",
       "gripper"]
JS = ("shoulder_pan", "elbow_flex")
SONDA = 50
PASO_MAX = 60
GANANCIA = 0.45
AMORTIGUA = 0.08
TOL_PX = 18.0
# La pegatina: rosa saturado. Medido en la escena real, H=155 S=135 V=181.
# SIN banda de tono baja: incluir 0-8 para "captar rojos" metia la MADERA CALIDA,
# que en esta luz cae justo ahi y es mucho mas extensa, asi que el centroide se
# iba de la pegatina a la mesa. El tono medido esta firmemente en magenta.
ROSA = dict(h_lo=138, h_hi=176, s_min=95, v_min=60, area_min=150)
# Umbrales MEDIDOS para separar el objeto de los reflejos: el objeto real da
# S=220 V=250 (azul vivo) y el reflejo azulado sobre el papel del tablero S=90
# V=93 (deslavado). Con s_min=80 ganaba el reflejo por ser mas extenso, y el
# lazo apuntaba al sitio equivocado.
AZUL = dict(h_lo=95, h_hi=135, s_min=145, v_min=130, area_min=200)


def encuentra_color(frame, cfg, que="la mancha", cerca_de=None, salto_max=120):
    """Centro de la mancha del color pedido. (centro, area) o (None, motivo).

    Con `cerca_de` se elige por CONTINUIDAD y no por tamano. Coger siempre la
    mayor hacia que el seguimiento saltara entre manchas distintas -- habia tres
    regiones azules en la escena -- y el jacobiano cambiaba de signo y de orden
    de magnitud entre iteraciones (+770, -898, +26), con lo que el lazo se
    estancaba en 54 px sin poder cerrar.
    """
    import cv2
    h = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    H, S, V = h[:, :, 0].astype(int), h[:, :, 1].astype(int), h[:, :, 2].astype(int)
    m = (H >= cfg["h_lo"]) & (H <= cfg["h_hi"]) & \
        (S >= cfg["s_min"]) & (V >= cfg["v_min"])
    m = cv2.morphologyEx(m.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    n, lab, st, ce = cv2.connectedComponentsWithStats(m, 8)
    if n < 2:
        return None, f"no veo {que}"
    cand = [k for k in range(1, n) if st[k, cv2.CC_STAT_AREA] >= cfg["area_min"]]
    if not cand:
        mayor = max(range(1, n), key=lambda k: st[k, cv2.CC_STAT_AREA])
        return None, f"{que}: solo {int(st[mayor, cv2.CC_STAT_AREA])} px"
    if cerca_de is None:
        i = max(cand, key=lambda k: st[k, cv2.CC_STAT_AREA])
    else:
        i = min(cand, key=lambda k: np.hypot(ce[k][0] - cerca_de[0],
                                             ce[k][1] - cerca_de[1]))
        if np.hypot(ce[i][0] - cerca_de[0], ce[i][1] - cerca_de[1]) > salto_max:
            return None, (f"{que}: la mas cercana esta a "
                          f"{np.hypot(ce[i][0]-cerca_de[0], ce[i][1]-cerca_de[1]):.0f} px "
                          "de donde estaba; no me fio")
    return (np.array([float(ce[i][0]), float(ce[i][1])]),
            int(st[i, cv2.CC_STAT_AREA])), None


def encuentra_rosa(frame, cfg=ROSA):
    return encuentra_color(frame, cfg, "la pegatina")


def encuentra_azul(frame, cfg=AZUL, cerca_de=None, salto_max=140):
    # El salto admisible depende de si el movimiento estaba ORDENADO: al medir el
    # jacobiano se mueve una articulacion a proposito y el objeto se desplaza
    # cientos de pixeles (se midieron hasta 770 px por 100 ticks), asi que un
    # umbral de continuidad estrecho ahi rechaza detecciones buenas. Tras el
    # paso correctivo, en cambio, el objeto deberia moverse poco.
    return encuentra_color(frame, cfg, "el objeto azul", cerca_de=cerca_de,
                           salto_max=salto_max)


def anota(frame, mira, objetivo, etiqueta, carpeta):
    import cv2
    v = frame.copy()
    if mira is not None:
        cv2.drawMarker(v, tuple(int(x) for x in mira), (0, 255, 255),
                       cv2.MARKER_CROSS, 30, 2)
        cv2.putText(v, "mira", (int(mira[0]) + 16, int(mira[1])), 0, 0.5,
                    (0, 255, 255), 2)
    if objetivo is not None:
        cv2.drawMarker(v, tuple(int(x) for x in objetivo), (0, 255, 0),
                       cv2.MARKER_TILTED_CROSS, 30, 2)
        cv2.putText(v, "objetivo", (int(objetivo[0]) + 16, int(objetivo[1])), 0,
                    0.5, (0, 255, 0), 2)
        if mira is not None:
            cv2.line(v, tuple(int(x) for x in mira),
                     tuple(int(x) for x in objetivo), (255, 255, 0), 1)
            cv2.putText(v, f"error {np.linalg.norm(objetivo-mira):.0f} px",
                        (8, 22), 0, 0.6, (255, 255, 0), 2)
    pathlib.Path(carpeta).mkdir(parents=True, exist_ok=True)
    cv2.imwrite(f"{carpeta}/{etiqueta}.jpg", v)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--objetivo", nargs=2, type=float, metavar=("U", "V"),
                   help="pixel del objeto en la imagen de la muneca")
    p.add_argument("--camara", type=int,
                   default=int(os.environ.get("LEX_XLE_CAMERA_LEFT_INDEX", "1")))
    p.add_argument("--port", default="/dev/cu.usbmodem5B610332201")
    p.add_argument("--id", default="xle_right")
    p.add_argument("--iteraciones", type=int, default=8)
    p.add_argument("--tol-px", type=float, default=TOL_PX)
    p.add_argument("--verificar", action="store_true",
                   help="solo mirar y guardar la imagen anotada, sin mover")
    p.add_argument("--fotos", default="/tmp/muneca")
    p.add_argument("--altura-vuelo", type=float, default=0.045,
                   help="metros que la PUNTA de la pinza debe mantener sobre la "
                        "mesa mientras se alinea")
    a = p.parse_args()

    import cv2
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.model.kinematics import RobotKinematics
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from contact_probe import Termostato

    cap = cv2.VideoCapture(a.camara)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(10):
        cap.read()

    def foto():
        for _ in range(4):
            cap.read()
        ok, f = cap.read()
        return f if ok else None

    f = foto()
    if f is None:
        sys.exit("la camara de muneca no da imagen")
    r, motivo = encuentra_rosa(f)
    if r is None:
        anota(f, None, None, "sin_pegatina", a.fotos)
        sys.exit(f"{motivo} -> {a.fotos}/sin_pegatina.jpg")
    mira, area = r
    objetivo = np.array(a.objetivo) if a.objetivo else None
    anota(f, mira, objetivo, "inicial", a.fotos)
    print(f"  punto de mira (pegatina) en ({mira[0]:.0f},{mira[1]:.0f}), "
          f"area {area} px -> {a.fotos}/inicial.jpg", flush=True)
    if objetivo is None or a.verificar:
        if objetivo is None:
            print("  sin --objetivo: solo he localizado el punto de mira", flush=True)
        cap.release()
        return 0

    rob = SO101Follower(SO101FollowerConfig(port=a.port, id=a.id))
    rob.bus.connect()
    termo = Termostato(rob.bus, blando=48, duro=50, reanudar=45)

    # Mantener la ALTURA mientras se alinea. Alinear mueve el codo, y mover el
    # codo BAJA la pinza: el lazo acabo con la punta apoyada en la mesa (z=-0.029
    # mas los +3.5 cm de desfase vertical dan justo la altura de la mesa), el
    # codo empujando contra ella, y el error estancado en 54 px. De las tres
    # componentes del desfase, la vertical fue la unica que quedo determinada
    # ayer (+3.5 cm, +-3 mm) -- y es justo la que hace falta aqui.
    plano = json.loads(pathlib.Path("calibration/table_plane_touch.json").read_text())
    n_pl = np.array(plano["normal"], np.float64)
    c_pl = np.array(plano["centroid"], np.float64)
    parcial = json.loads(
        pathlib.Path("calibration/tool_offset_left_partial.json").read_text())
    dz_punta = float(parcial["z_m"])
    kin = RobotKinematics(
        urdf_path=os.environ.get("LEX_XLE_URDF_PATH", ""), joint_names=ARM,
        target_frame_name=os.environ.get("LEX_XLE_URDF_TARGET_FRAME",
                                         "gripper_frame_link"))

    def altura_punta():
        deg = rob.bus.sync_read("Present_Position", num_retry=3)
        T = np.asarray(kin.forward_kinematics(
            np.array([float(deg[j]) for j in ARM])), np.float64)
        return float((T[:3, 3] - c_pl) @ n_pl) - dz_punta
    try:
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False)
        cur = {j: int(rob.bus.read("Present_Position", j, normalize=False))
               for j in ARM}
        L = {j: (int(rob.bus.read("Min_Position_Limit", j, normalize=False)),
                 int(rob.bus.read("Max_Position_Limit", j, normalize=False)))
             for j in JS}

        def objeto_ahora():
            """El objetivo se da en pixeles del PRIMER fotograma; al moverse la
            camara se mueve con la escena, asi que se vuelve a localizar por
            correlacion del entorno del punto."""
            return None     # se resuelve con el jacobiano abajo

        obj_px = objetivo.copy()
        for it in range(a.iteraciones):
            if not termo.comprobar():
                break
            err = obj_px - mira
            print(f"  {it}: objeto en ({obj_px[0]:.0f},{obj_px[1]:.0f}), error "
                  f"{np.linalg.norm(err):5.1f} px", flush=True)
            if np.linalg.norm(err) < a.tol_px:
                print(f"  LLEGADA en {it} iteraciones", flush=True)
                break
            # jacobiano: cuanto se mueve el OBJETO en la imagen por tick
            Jm = np.zeros((2, 2))
            base = foto()
            for k, j in enumerate(JS):
                v = int(np.clip(cur[j] + SONDA, L[j][0] + 30, L[j][1] - 30))
                if v == cur[j]:
                    v = int(np.clip(cur[j] - SONDA, L[j][0] + 30, L[j][1] - 30))
                rob.bus.write("Goal_Position", j, v, normalize=False)
                time.sleep(1.0)
                f2 = foto()
                rob.bus.write("Goal_Position", j, cur[j], normalize=False)
                time.sleep(1.0)
                if base is None or f2 is None:
                    sys.exit("me quede sin imagen midiendo el jacobiano")
                # Se sigue el OBJETO detectandolo, no correlacionando la imagen:
                # la vista de la muneca es casi toda madera lisa, y la
                # correlacion de fase necesita textura -- devolvia 1-5 px por
                # cada 100 ticks cuando el movimiento real era ~30, asi que el
                # lazo avanzaba un pixel por vuelta y no convergia nunca.
                r1, _m1 = encuentra_azul(base, cerca_de=obj_px, salto_max=160)
                r2, _m2 = encuentra_azul(f2, cerca_de=obj_px, salto_max=450)
                if r1 is None or r2 is None:
                    print(f"  perdi el objeto midiendo {j}; paro", flush=True)
                    return 1
                Jm[:, k] = (r2[0] - r1[0]) / (v - cur[j])
            print(f"    jacobiano: pan ({Jm[0,0]*100:+.1f},{Jm[1,0]*100:+.1f}) "
                  f"codo ({Jm[0,1]*100:+.1f},{Jm[1,1]*100:+.1f}) px/100 ticks",
                  flush=True)
            if abs(np.linalg.det(Jm)) < 1e-9:
                print("  jacobiano degenerado; paro", flush=True)
                break
            # OJO AL SIGNO. Aqui la camara va en el brazo, asi que quien se mueve
            # en la imagen es el OBJETO, y hay que llevarlo a una mira fija: el
            # desplazamiento pedido es (mira - objeto) = -err. En el servocontrol
            # desde la torre era al reves -- se movia la pinza hacia un objetivo
            # fijo -- y copiar aquella estructura sin invertir el signo hacia que
            # el lazo se alejara: 157 -> 204 -> 245 -> 292 px.
            JtJ = Jm.T @ Jm
            d = np.linalg.solve(JtJ + AMORTIGUA * np.trace(JtJ) * np.eye(2),
                                Jm.T @ (-err)) * GANANCIA
            esc = min(1.0, PASO_MAX / max(abs(d).max(), 1e-9))
            for k, j in enumerate(JS):
                cur[j] = int(np.clip(cur[j] + d[k] * esc, L[j][0] + 30, L[j][1] - 30))
                rob.bus.write("Goal_Position", j, cur[j], normalize=False)
            time.sleep(1.2)
            # Recuperar la altura que el movimiento del codo se ha llevado
            h = altura_punta()
            if abs(h - a.altura_vuelo) > 0.012:
                lo_l, hi_l = (int(rob.bus.read("Min_Position_Limit", "shoulder_lift",
                                               normalize=False)),
                              int(rob.bus.read("Max_Position_Limit", "shoulder_lift",
                                               normalize=False)))
                lift = int(rob.bus.read("Present_Position", "shoulder_lift",
                                        normalize=False))
                h0 = h
                rob.bus.write("Goal_Position", "shoulder_lift",
                              int(np.clip(lift + 30, lo_l + 30, hi_l - 30)),
                              normalize=False)
                time.sleep(0.7)
                sgn = +1 if altura_punta() > h0 else -1
                rob.bus.write("Goal_Position", "shoulder_lift", lift,
                              normalize=False)
                time.sleep(0.5)
                for _ in range(14):
                    h = altura_punta()
                    if abs(h - a.altura_vuelo) < 0.008:
                        break
                    paso = 18 if h < a.altura_vuelo else -18
                    lift = int(np.clip(lift + sgn * paso, lo_l + 30, hi_l - 30))
                    rob.bus.write("Goal_Position", "shoulder_lift", lift,
                                  normalize=False)
                    time.sleep(0.35)
                print(f"    altura recuperada: {h*100:+.1f} cm sobre la mesa",
                      flush=True)
            ahora = foto()
            ro, mo = encuentra_azul(ahora, cerca_de=obj_px)
            if ro is None:
                print(f"  {mo}; paro", flush=True)
                break
            obj_px = ro[0]
            r2, _m = encuentra_rosa(ahora)
            if r2 is not None:
                mira = r2[0]           # la pegatina no deberia moverse, pero se remide
            anota(ahora, mira, obj_px, f"iter{it:02d}", a.fotos)
    finally:
        try:
            rob.bus.disconnect(disable_torque=False)
        except Exception:
            pass
        cap.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
