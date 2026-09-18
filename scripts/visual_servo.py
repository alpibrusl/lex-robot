#!/usr/bin/env python3
"""Llevar la pinza a un punto de la IMAGEN, corrigiendo el error que se ve.

Esto existe porque la cadena abierta no da: el desfase entre gripper_frame_link y
el punto que de verdad toca NO es medible por contacto con esta pinza (ver
calibration/tool_offset_left_partial.json), y sin el, cualquier calculo de "mueve
la pinza a estas coordenadas" arrastra centimetros de error que nadie detecta.

El lazo cerrado no necesita ese desfase. Se mira donde ESTA la pinza, se compara
con donde se la quiere, y se corrige. Tampoco necesita los extrinsecos ni el
plano de la mesa: trabaja en pixeles, que es donde la medida es buena -- el
detector de pinza por diferencia de movimiento repite a 0.6 px, la medida mas
limpia de toda la calibracion.

El jacobiano de imagen (cuantos pixeles se mueve la pinza por tick de cada
articulacion) se MIDE en la postura actual y se reutiliza unas iteraciones,
porque medirlo cuesta dos deteccciones y cambia despacio.
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
JS = ("shoulder_pan", "elbow_flex")     # dos articulaciones para dos ejes de imagen
SONDA = 60                              # ticks para medir el jacobiano
PASO_MAX = 60                           # ticks por iteracion
TOL_PX = 12.0
GANANCIA = 0.45                         # fraccion del paso que corrige el error
AMORTIGUA = 0.08                        # Levenberg: frena cuando el jacobiano es malo
SALTO_MAX_PX = 140                      # una deteccion que salta mas que esto miente
OSCURO_MAX = 70                         # la pinza es negra; la sombra sobre madera no


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--objetivo", nargs=2, type=float, metavar=("U", "V"),
                   help="pixel destino; por defecto, el centro de la imagen")
    p.add_argument("--port", default="/dev/cu.usbmodem5B610332201")
    p.add_argument("--id", default="xle_right")
    p.add_argument("--camara", type=int,
                   default=int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "0")))
    p.add_argument("--iteraciones", type=int, default=8)
    p.add_argument("--verificar", action="store_true",
                   help="SOLO detectar y guardar la imagen anotada, sin mover nada")
    p.add_argument("--fotos", default="/tmp/servo",
                   help="donde guardar lo que el lazo ve en cada iteracion")
    p.add_argument("--tol-px", type=float, default=TOL_PX)
    # Los umbrales del termostato se fijaron para el sondeo de contactos, que
    # empuja contra la mesa. El servocontrol son giros pequenos en el aire y
    # carga mucho menos, asi que esperar a 40 C cuesta veinte minutos sin
    # motivo. El limite de seguridad (aborto) no se toca.
    p.add_argument("--temp-pausa", type=float, default=48)
    p.add_argument("--temp-reanudar", type=float, default=45)
    a = p.parse_args()

    import cv2
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from contact_probe import Termostato

    cap = cv2.VideoCapture(a.camara)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(10):
        cap.read()
    objetivo = np.array(a.objetivo if a.objetivo else [320.0, 240.0])

    rob = SO101Follower(SO101FollowerConfig(port=a.port, id=a.id))
    rob.bus.connect()
    termo = Termostato(rob.bus, blando=a.temp_pausa, duro=50,
                       reanudar=a.temp_reanudar)

    def gris():
        for _ in range(4):
            cap.read()
        ok, f = cap.read()
        return cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32) if ok else None

    def donde_esta(etiqueta=""):
        """Pixel de la pinza, abriendola y cerrandola. Repetible a 0.6 px.

        GUARDA lo que ve. El lazo diverio una vez y acabo pinzando el carro
        porque yo leia el pixel que devolvia esta funcion sin comprobar nunca
        que habia ahi: el detector coge la mancha de movimiento MAYOR, y al
        abrir la pinza contra la malla del carro lo que se movia era otra cosa.
        Un numero bien calculado sobre algo que no es lo que uno supone.
        """
        c = int(rob.bus.read("Present_Position", "gripper", normalize=False))
        hi = int(rob.bus.read("Max_Position_Limit", "gripper", normalize=False))
        lo = int(rob.bus.read("Min_Position_Limit", "gripper", normalize=False))
        t = int(min(c + 700, hi - 20)) if hi - c > 400 else int(max(c - 700, lo + 20))
        a0 = gris()
        rob.bus.write("Torque_Enable", "gripper", 1, normalize=False)
        time.sleep(0.2)
        rob.bus.write("Goal_Position", "gripper", t, normalize=False)
        time.sleep(1.4)
        b0 = gris()
        rob.bus.write("Goal_Position", "gripper", c, normalize=False)
        time.sleep(1.2)
        if a0 is None or b0 is None:
            return None
        d = np.abs(b0 - a0)
        d[d < 12] = 0
        # La pinza es NEGRA; la sombra que proyecta cae sobre madera clara y tiene
        # MAS contraste que ella, asi que la mancha de movimiento se extendia por
        # la mesa y arrastraba el centroide. Se exige que el pixel sea oscuro en
        # alguno de los dos fotogramas: donde estuvo la pinza lo es, y la madera
        # sombreada sigue siendo gris medio.
        oscuro = np.minimum(a0, b0) < OSCURO_MAX
        m = cv2.morphologyEx(((d > 0) & oscuro).astype(np.uint8), cv2.MORPH_OPEN,
                             np.ones((5, 5), np.uint8))
        nn, _l, st, ce = cv2.connectedComponentsWithStats(m, 8)
        if nn < 2:
            return None
        i = max(range(1, nn), key=lambda z: st[z, cv2.CC_STAT_AREA])
        area = int(st[i, cv2.CC_STAT_AREA])
        cen = np.array([float(ce[i][0]), float(ce[i][1])])
        if etiqueta:
            vis = cv2.cvtColor(b0.astype(np.uint8), cv2.COLOR_GRAY2BGR)
            vis[_l == i] = (0.4 * vis[_l == i] + np.array([0, 0, 153])).astype(np.uint8)
            x, y, w, h = (st[i, cv2.CC_STAT_LEFT], st[i, cv2.CC_STAT_TOP],
                          st[i, cv2.CC_STAT_WIDTH], st[i, cv2.CC_STAT_HEIGHT])
            cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 0, 255), 2)
            cv2.drawMarker(vis, (int(cen[0]), int(cen[1])), (0, 255, 255),
                           cv2.MARKER_CROSS, 26, 2)
            cv2.drawMarker(vis, (int(objetivo[0]), int(objetivo[1])), (0, 255, 0),
                           cv2.MARKER_TILTED_CROSS, 26, 2)
            cv2.putText(vis, f"{etiqueta} area={area} en ({cen[0]:.0f},{cen[1]:.0f})",
                        (8, 22), 0, 0.55, (0, 255, 255), 2)
            pathlib.Path(a.fotos).mkdir(parents=True, exist_ok=True)
            cv2.imwrite(f"{a.fotos}/{etiqueta}.jpg", vis)
        if area < 400:
            return None
        return cen

    try:
        # En modo verificar NO se fija el par del brazo: solo hace falta el de la
        # pinza, que la deteccion abre y cierra. Fijarlo todo dejaba el brazo
        # rigido tras una operacion que unicamente MIRA, y hay que soltarlo a mano
        # para recolocarlo -- justo lo contrario de lo util.
        for j in (["gripper"] if a.verificar else ARM):
            rob.bus.write("Torque_Enable", j, 1, normalize=False)
        cur = {j: int(rob.bus.read("Present_Position", j, normalize=False))
               for j in ARM}
        L = {j: (int(rob.bus.read("Min_Position_Limit", j, normalize=False)),
                 int(rob.bus.read("Max_Position_Limit", j, normalize=False)))
             for j in JS}
        px = donde_esta("inicial")
        if px is None:
            sys.exit("no veo la pinza; colocala donde la camara la vea")
        if a.verificar:
            print(f"  detectado en ({px[0]:.0f},{px[1]:.0f}) -> "
                  f"{a.fotos}/inicial.jpg", flush=True)
            print("  MIRA LA IMAGEN antes de dejarme mover: si el recuadro rojo no "
                  "esta sobre la pinza, el lazo perseguiria otra cosa.", flush=True)
            for j in ARM:
                try:
                    rob.bus.write("Torque_Enable", j, 0, normalize=False)
                except Exception:
                    pass
            print("  brazo SUELTO (solo he mirado)", flush=True)
            return 0
        print(f"  pinza en ({px[0]:.0f},{px[1]:.0f}), objetivo "
              f"({objetivo[0]:.0f},{objetivo[1]:.0f}), error "
              f"{np.linalg.norm(objetivo-px):.0f} px", flush=True)

        Jm = None
        for it in range(a.iteraciones):
            if not termo.comprobar():
                break
            err = objetivo - px
            if np.linalg.norm(err) < a.tol_px:
                print(f"  LLEGADA en {it} iteraciones, error "
                      f"{np.linalg.norm(err):.1f} px", flush=True)
                break
            # Medir el jacobiano CADA iteracion. Reutilizarlo tres veces parecia
            # ahorro y fue la causa de la divergencia: entre dos medidas el termino
            # del codo paso de +188.7 a +14.3 px/100 ticks (factor 13), asi que el
            # lazo corregia con una ganancia equivocada y se alejaba.
            if True:
                # Medir el jacobiano de IMAGEN en la postura actual. Se reutiliza
                # unas iteraciones: medirlo cuesta dos detecciones y cambia poco.
                Jm = np.zeros((2, 2))
                for k, j in enumerate(JS):
                    v = int(np.clip(cur[j] + SONDA, L[j][0] + 30, L[j][1] - 30))
                    if v == cur[j]:
                        v = int(np.clip(cur[j] - SONDA, L[j][0] + 30, L[j][1] - 30))
                    rob.bus.write("Goal_Position", j, v, normalize=False)
                    time.sleep(1.0)
                    p2 = donde_esta(f"jac{it:02d}_{j[:4]}")
                    rob.bus.write("Goal_Position", j, cur[j], normalize=False)
                    time.sleep(1.0)
                    if p2 is None:
                        print(f"  perdi la pinza midiendo {j}; paro", flush=True)
                        return 1
                    Jm[:, k] = (p2 - px) / (v - cur[j])
                print(f"    jacobiano: pan {Jm[0,0]*100:+.1f},{Jm[1,0]*100:+.1f} "
                      f"codo {Jm[0,1]*100:+.1f},{Jm[1,1]*100:+.1f} px/100 ticks",
                      flush=True)
                if abs(np.linalg.det(Jm)) < 1e-9:
                    print("  jacobiano degenerado; paro", flush=True)
                    return 1
            # Minimos cuadrados AMORTIGUADOS en vez del paso exacto: con un
            # jacobiano mal condicionado, resolver exacto pide pasos enormes en la
            # direccion peor conocida. Y ganancia < 1, porque acercarse despacio y
            # volver a medir es mas fiable que fiarse de un modelo que cambia.
            JtJ = Jm.T @ Jm
            d = np.linalg.solve(JtJ + AMORTIGUA * np.trace(JtJ) * np.eye(2),
                                Jm.T @ err) * GANANCIA
            esc = min(1.0, PASO_MAX / max(abs(d).max(), 1e-9))
            for k, j in enumerate(JS):
                cur[j] = int(np.clip(cur[j] + d[k] * esc, L[j][0] + 30, L[j][1] - 30))
                rob.bus.write("Goal_Position", j, cur[j], normalize=False)
            time.sleep(1.2)
            nuevo = donde_esta(f"iter{it:02d}")
            if nuevo is None:
                print("  perdi la pinza de vista; paro", flush=True)
                break
            # Una deteccion que salta muchisimo no es la pinza: el detector coge
            # la mancha de movimiento mayor, y puede engancharse a otra cosa (el
            # otro brazo, una sombra). Se descarta y se vuelve a mirar.
            if np.linalg.norm(nuevo - px) > SALTO_MAX_PX:
                print(f"    deteccion sospechosa: salto de "
                      f"{np.linalg.norm(nuevo-px):.0f} px; la ignoro", flush=True)
                nuevo = donde_esta(f"iter{it:02d}bis")
                if nuevo is None or np.linalg.norm(nuevo - px) > SALTO_MAX_PX:
                    print("  no consigo una deteccion fiable; paro", flush=True)
                    break
            print(f"  {it}: ({px[0]:.0f},{px[1]:.0f}) -> ({nuevo[0]:.0f},"
                  f"{nuevo[1]:.0f})  error {np.linalg.norm(objetivo-nuevo):5.1f} px",
                  flush=True)
            px = nuevo
        else:
            print(f"  sin converger en {a.iteraciones} iteraciones, error "
                  f"{np.linalg.norm(objetivo-px):.1f} px", flush=True)
    finally:
        try:
            rob.bus.disconnect(disable_torque=False)
        except Exception:
            pass
        cap.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
