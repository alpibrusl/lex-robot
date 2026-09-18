"""Practicar con el teclado sin grabar nada. Se deja corriendo y ya esta.

Con varios brazos: se cambia en caliente con 1 y 2. El brazo que no esta
activo conserva el par, asi que se queda donde lo dejaste en vez de caerse,
y al volver a el retoma desde donde este de verdad (el tope de 8 unidades de
DeltaAPosicion reengancha solo).

Diferencias a proposito con grabar_demos.sh:

- Sin camaras. Para practicar no aportan nada y el bucle va mas suelto.
- El par NO se suelta al salir (disable_torque_on_disconnect=False). Lo de
  serie es soltarlo, y entonces el brazo se desploma sobre la mesa en cuanto
  pulsas Ctrl-C. Ya nos paso varias veces en este proyecto.
- Vigila la temperatura del hombro. Si lo dejas encendido con el brazo en
  alto, el servo que sostiene todo el peso se calienta aunque no muevas nada.

OJO con el bus del brazo IZQUIERDO: lleva tambien la TORRE en los ids 7 y 8
(medido: pan 1508 / tilt 3386, el angulo con el que se grabaron las
demostraciones). Aqui solo se declaran los ids 1-6, asi que la torre no se
toca; no añadas ids sin pensarlo.

Ejecutalo DESDE TU TERMINAL: el permiso de Accesibilidad lo tiene Terminal.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from lerobot.processor import (  # noqa: E402
    RobotProcessorPipeline,
    robot_action_observation_to_transition,
    transition_to_robot_action,
)
from lerobot.robots.so_follower.config_so_follower import SOFollowerRobotConfig  # noqa: E402
from lerobot.robots.utils import make_robot_from_config  # noqa: E402
from lerobot.teleoperators.utils import make_teleoperator_from_config  # noqa: E402

from teclado_articular import DeltaAPosicion, TecladoArticularConfig  # noqa: E402

# OJO con los nombres de perfil: estan CRUZADOS respecto al lado fisico, y es
# a proposito. `xle_right` es el perfil del brazo IZQUIERDO. Son solo claves de
# busqueda; lo que importa es que cada puerto reciba el perfil que coincide con
# la EEPROM de sus propios servos, verificado 6/6 en ambos lados. No lo
# "arregles": divergiria de las copias en calibration/ de la rama
# pi-env-camera-map, que usan estos nombres.
#
# El lado se identifica por los servos auxiliares de cada bus, no por la
# etiqueta: torre (ids 7,8) = izquierdo, ruedas (ids 9,10) = derecho. Medido
# hoy otra vez: en 610332201 los ids 7/8 leen pan 1508 / tilt 3386, que es la
# torre en su angulo de grabacion.
BRAZOS = [
    ("izquierdo", "/dev/cu.usbmodem5B610332201", "xle_right"),
    ("derecho", "/dev/cu.usbmodem5B3D0437151", "xle_left"),
]
TECLAS_BRAZO = {"1": 0, "2": 1}  # no chocan con las de mover

FPS = 30
VIGILADO = "shoulder_lift"  # el que carga con todo el peso
AVISO_C = 45
PARADA_C = 50
CADA_S = 2.0  # no saturar el bus con lecturas de temperatura


class Brazo:
    """Un brazo conectado, con su tuberia y su termometro."""

    def __init__(self, nombre: str, robot):
        self.nombre = nombre
        self.robot = robot
        self.tuberia = RobotProcessorPipeline[tuple[dict, dict], dict](
            steps=[DeltaAPosicion()],
            to_transition=robot_action_observation_to_transition,
            to_output=transition_to_robot_action,
        )
        self.temperatura = 0
        self.pico = 0
        self._ultima = 0.0

    def mover(self, accion: dict) -> dict:
        obs = self.robot.get_observation()
        self.robot.send_action(self.tuberia((accion, obs)))
        return obs

    def medir(self, ahora: float) -> None:
        if ahora - self._ultima <= CADA_S:
            return
        self._ultima = ahora
        # Mediana de tres: una lectura suelta del bus puede venir corrupta, y
        # de este numero depende parar o seguir.
        lecturas = []
        for _ in range(3):
            try:
                lecturas.append(
                    int(self.robot.bus.read("Present_Temperature", VIGILADO, normalize=False))
                )
            except Exception:
                pass
        if lecturas:
            self.temperatura = sorted(lecturas)[len(lecturas) // 2]
            self.pico = max(self.pico, self.temperatura)


def conectar(pedidos: list[str]) -> list[Brazo]:
    brazos = []
    for nombre, puerto, ident in BRAZOS:
        if pedidos and nombre not in pedidos:
            continue
        robot = make_robot_from_config(
            SOFollowerRobotConfig(
                port=puerto,
                id=ident,
                max_relative_target=12.0,
                disable_torque_on_disconnect=False,  # que no se desplome al salir
                cameras={},
            )
        )
        try:
            # calibrate=False: sin esto, un brazo sin calibrar arranca la
            # calibracion interactiva sin avisar, y te pide mover el brazo
            # por todo su recorrido cuando solo querias practicar.
            robot.connect(calibrate=False)
        except Exception as e:
            print(f"  {nombre}: no se pudo conectar ({type(e).__name__}: {str(e)[:60]})")
            continue
        if not robot.is_calibrated:
            print(
                f"  {nombre}: SIN CALIBRAR. Los servos no guardan su recorrido, asi que\n"
                f"           las posiciones no significan nada todavia. Calibralo una vez:\n"
                f"             lerobot-calibrate --robot.type=so101_follower \\\n"
                f"               --robot.port={puerto} --robot.id={ident}"
            )
            try:
                robot.disconnect()
            except Exception:
                pass
            continue
        print(f"  {nombre}: listo")
        brazos.append(Brazo(nombre, robot))
    return brazos


def ayuda(brazos: list[Brazo]) -> None:
    print("\n  w/s  girar la base      y/h  muñeca arriba/abajo")
    print("  e/d  hombro             u/j  girar la muñeca")
    print("  t/g  codo               i/k  abrir/cerrar la pinza")
    if len(brazos) > 1:
        cambio = "   ".join(f"{t} = {brazos[i].nombre}" for t, i in TECLAS_BRAZO.items() if i < len(brazos))
        print(f"\n  Cambiar de brazo:  {cambio}")
        print("  El brazo inactivo conserva el par: se queda donde lo dejaste.")
    print("\n  Se combinan pulsando a la vez. Shift = cuarto de velocidad.")
    print("  Esc o Ctrl-C para salir; los brazos se quedan SUJETOS, no se caen.\n")


def main() -> int:
    import HIServices

    if not bool(HIServices.AXIsProcessTrusted()):
        print(
            "Este proceso no tiene permiso de Accesibilidad.\n"
            "Lanzalo desde Terminal: el permiso es de Terminal, no de Claude.",
            file=sys.stderr,
        )
        return 1

    pedidos = [a.lower() for a in sys.argv[1:] if not a.startswith("-")]
    desconocidos = [p for p in pedidos if p not in {n for n, _, _ in BRAZOS}]
    if desconocidos:
        print(f"Brazo desconocido: {', '.join(desconocidos)}. Usa: izquierdo, derecho", file=sys.stderr)
        return 1

    print("Conectando:")
    brazos = conectar(pedidos)
    if not brazos:
        print("\nNingun brazo utilizable.", file=sys.stderr)
        return 1

    teleop = make_teleoperator_from_config(TecladoArticularConfig())
    teleop.connect()
    ayuda(brazos)

    activo, motivo = 0, "Esc"
    periodo = 1.0 / FPS
    try:
        while teleop.is_connected:
            ciclo = time.perf_counter()

            # Leer el cambio de brazo antes de mover, para que la tecla no se
            # pierda en el mismo fotograma en que se pulsa.
            for tecla, indice in TECLAS_BRAZO.items():
                if teleop.current_pressed.get(tecla) and indice < len(brazos):
                    activo = indice

            brazo = brazos[activo]
            obs = brazo.mover(teleop.get_action())
            for b in brazos:
                b.medir(ciclo)

            caliente = [b for b in brazos if b.temperatura >= PARADA_C]
            if caliente:
                motivo = f"{caliente[0].nombre} {VIGILADO} a {caliente[0].temperatura} C"
                break

            marca = "  CALIENTE" if brazo.temperatura >= AVISO_C else ""
            posturas = "  ".join(
                f"{k.removesuffix('.pos')[:5]}:{v:6.1f}" for k, v in sorted(obs.items())
            )
            etiqueta = brazo.nombre[:3] if len(brazos) > 1 else ""
            print(f"\r  {etiqueta:3s} {brazo.temperatura:2d}C{marca}  {posturas}   ", end="", flush=True)

            espera = periodo - (time.perf_counter() - ciclo)
            if espera > 0:
                time.sleep(espera)
    except KeyboardInterrupt:
        motivo = "Ctrl-C"
    finally:
        print()
        teleop.disconnect()
        for b in brazos:
            try:
                b.robot.disconnect()  # con el par PUESTO, por la config de arriba
            except Exception:
                pass

    picos = "  ".join(f"{b.nombre} {b.pico} C" for b in brazos)
    print(f"\nFin ({motivo}). Pico de temperatura: {picos}.")
    print("Los brazos siguen SUJETOS por los servos: al salir no se caen.")
    print("Para dejarlos libres cuando termines:")
    print("    python scripts/soltar_servos.py")
    if any(b.temperatura >= PARADA_C for b in brazos):
        print(
            f"\nSe paro por calor. Dejalo enfriar por debajo de {AVISO_C} C antes de\n"
            "seguir. Si lo vas a tener mucho rato encendido, bajalo apoyado en la\n"
            "mesa: lo que calienta es el hombro sosteniendo el brazo en alto."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
