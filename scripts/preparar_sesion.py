"""Comprobar el robot ANTES de grabar. Barato ahora, carisimo despues.

La consistencia de camara es lo mas fragil de todo esto: si el angulo de la
torre cambia entre grabar y ejecutar, lo que la politica aprendio a ver deja
de coincidir con lo que ve, y no funciona. Y no avisa: graba perfectamente
cincuenta episodios inservibles.

Asi que antes de cada sesion:

  - la torre esta en el angulo de referencia (pan 1508 / tilt 3386)
  - las tres camaras abren, dan imagen distinta entre si y se ve algo
  - los brazos responden, estan calibrados y no vienen calientes
  - hay sitio en disco

Uso:  python scripts/preparar_sesion.py [--brazo izquierdo|derecho]
"""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "sidecar"))

# Medido y fijado: es el angulo con el que se grabaron las demostraciones.
TORRE_REF = {"pan": 1508, "tilt": 3386}
TORRE_TOLERANCIA = 12      # ticks; ~1 grado
TORRE_BUS = "/dev/cu.usbmodem5B610332201"  # la torre son los ids 7 y 8 de este bus
TORRE_IDS = {"pan": 7, "tilt": 8}

BRAZOS = {
    "izquierdo": ("/dev/cu.usbmodem5B610332201", "xle_right", 1),
    "derecho": ("/dev/cu.usbmodem5B3D0437151", "xle_left", 2),
}
CAMARAS = {"cabeza": 0, "muñeca izquierda": 1, "muñeca derecha": 2}

TEMP_MAX = 42       # por encima de esto, arrancar ya es empezar con deuda
DISCO_MIN_GB = 5.0  # ~25 MB por episodio de 25 s con dos camaras


def _bus(puerto, ids):
    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    m = {n: Motor(i, "sts3215", MotorNormMode.RANGE_M100_100) for n, i in ids.items()}
    b = FeetechMotorsBus(port=puerto, motors=m)
    b.connect(handshake=False)
    return b


def mirar_torre() -> bool:
    # Reintenta: este bus suelta SerialException de vez en cuando.
    for intento in range(3):
        try:
            bus = _bus(TORRE_BUS, TORRE_IDS)
            try:
                leido = {n: int(bus.read("Present_Position", n, normalize=False)) for n in TORRE_IDS}
            finally:
                bus.disconnect(disable_torque=False)  # la torre NO se suelta nunca
            desvios = {n: leido[n] - TORRE_REF[n] for n in TORRE_REF}
            fuera = {n: d for n, d in desvios.items() if abs(d) > TORRE_TOLERANCIA}
            detalle = "  ".join(f"{n}={leido[n]} ({desvios[n]:+d})" for n in TORRE_REF)
            if fuera:
                print(f"  TORRE MOVIDA: {detalle}")
                print(f"    Referencia: pan {TORRE_REF['pan']} tilt {TORRE_REF['tilt']}. Reponla antes")
                print("    de grabar, o lo grabado hoy no valdra con lo de antes:")
                print(f"      python sidecar/tower.py --port {TORRE_BUS} \\")
                print(f"        --pan {TORRE_REF['pan']} --tilt {TORRE_REF['tilt']}")
                return False
            print(f"  torre en su sitio: {detalle}")
            return True
        except Exception as e:
            if intento == 2:
                print(f"  TORRE: no se pudo leer ({type(e).__name__})")
                return False
    return False


def mirar_camaras() -> bool:
    import cv2
    import numpy as np

    import vision

    fotos, bien, mudas = {}, True, 0
    for nombre, indice in CAMARAS.items():
        cap = cv2.VideoCapture(indice)
        try:
            for _ in range(8):  # calentar: las primeras salen oscuras
                cap.read()
            ok, f = cap.read()
        finally:
            cap.release()
        if not ok or f is None:
            print(f"  {nombre} (indice {indice}): NO DA IMAGEN")
            bien = False
            mudas += 1
            continue
        brillo, contraste, sirve = vision.calidad(f)
        fotos[nombre] = f
        estado = "ok" if sirve else "DEMASIADO OSCURA O PLANA"
        print(f"  {nombre} (indice {indice}): brillo {brillo:5.1f}  contraste {contraste:5.1f}  {estado}")
        bien &= sirve

    # Las tres a la vez mudas casi nunca es hardware: es el permiso de camara,
    # que en macOS lo tiene el proceso RESPONSABLE. Terminal lo tiene concedido;
    # el proceso de Claude no. Decir "no da imagen" a secas mandaria a buscar un
    # cable que esta perfectamente bien.
    if mudas == len(CAMARAS):
        print("\n  Las TRES mudas a la vez: casi seguro es el permiso de camara,")
        print("  no el hardware. Lanza esto desde TU Terminal, no desde Claude.")
        print("  Si desde Terminal tampoco, mira Ajustes > Privacidad > Camara.")
        return False

    # Que no sean la misma camara dos veces: un replug puede reordenar indices
    # y entonces grabarias dos vistas identicas creyendo que son dos.
    nombres = list(fotos)
    for i in range(len(nombres)):
        for j in range(i + 1, len(nombres)):
            a, b = fotos[nombres[i]], fotos[nombres[j]]
            if a.shape == b.shape and float(np.abs(a.astype(float) - b.astype(float)).mean()) < 3.0:
                print(f"  {nombres[i]} y {nombres[j]} DAN LA MISMA IMAGEN: indices reordenados")
                bien = False
    return bien


def mirar_brazo(nombre: str) -> bool:
    from lerobot.robots.so_follower.config_so_follower import SOFollowerRobotConfig
    from lerobot.robots.utils import make_robot_from_config

    puerto, perfil, camara = BRAZOS[nombre]
    robot = make_robot_from_config(
        SOFollowerRobotConfig(port=puerto, id=perfil, disable_torque_on_disconnect=False, cameras={})
    )
    try:
        robot.connect(calibrate=False)
    except Exception as e:
        print(f"  brazo {nombre}: NO RESPONDE ({type(e).__name__})")
        return False
    try:
        if not robot.is_calibrated:
            print(f"  brazo {nombre}: SIN CALIBRAR (perfil {perfil})")
            return False
        temps = []
        for eje in ("shoulder_lift", "elbow_flex"):
            try:
                temps.append(int(robot.bus.read("Present_Temperature", eje, normalize=False)))
            except Exception:
                pass
        t = max(temps) if temps else 0
        if t > TEMP_MAX:
            print(f"  brazo {nombre}: CALIENTE YA ({t} C). Dejalo enfriar o durara poco la sesion")
            return False
        print(f"  brazo {nombre}: listo (perfil {perfil}, muñeca en camara {camara}, {t} C)")
        return True
    finally:
        try:
            robot.disconnect()
        except Exception:
            pass


def main() -> int:
    brazo = "izquierdo"
    if "--brazo" in sys.argv:
        brazo = sys.argv[sys.argv.index("--brazo") + 1]
    if brazo not in BRAZOS:
        print(f"Brazo desconocido: {brazo}. Usa izquierdo o derecho", file=sys.stderr)
        return 1

    print("Torre:")
    ok = mirar_torre()
    print("\nCamaras:")
    ok &= mirar_camaras()
    print(f"\nBrazo:")
    ok &= mirar_brazo(brazo)

    libre = shutil.disk_usage(Path.home()).free / 1e9
    print(f"\nDisco: {libre:.1f} GB libres", end="")
    if libre < DISCO_MIN_GB:
        print(f"  MENOS DE {DISCO_MIN_GB} GB: no cabe una sesion")
        ok = False
    else:
        print("  (~25 MB por episodio)")

    if ok:
        print("\nTodo en orden. A grabar.")
        return 0
    print("\nHay algo que arreglar antes de grabar. Grabar con esto asi produce\nepisodios que parecen buenos y no sirven.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
