"""Practicar con el teclado sin grabar nada. Se deja corriendo y ya esta.

Diferencias a proposito con grabar_demos.sh:

- Sin camaras. Para practicar no aportan nada y el bucle va mas suelto.
- El par NO se suelta al salir (disable_torque_on_disconnect=False). Lo de
  serie es soltarlo, y entonces el brazo se desploma sobre la mesa en cuanto
  pulsas Ctrl-C. Ya nos paso varias veces en este proyecto.
- Vigila la temperatura del hombro. Si lo dejas encendido con el brazo en
  alto, el servo que sostiene todo el peso se calienta aunque no muevas nada.

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

PUERTO = "/dev/cu.usbmodem5B610332201"
BRAZO = "xle_right"
FPS = 30

VIGILADO = "shoulder_lift"  # el que carga con todo el peso
AVISO_C = 45
PARADA_C = 50
CADA_S = 2.0  # no saturar el bus con lecturas de temperatura


def ayuda() -> None:
    print("\n  w/s  girar la base      y/h  muñeca arriba/abajo")
    print("  e/d  hombro             u/j  girar la muñeca")
    print("  t/g  codo               i/k  abrir/cerrar la pinza")
    print("\n  Se combinan pulsando a la vez. Shift = cuarto de velocidad.")
    print("  Esc o Ctrl-C para salir; el brazo se queda SUJETO, no se cae.\n")


def main() -> int:
    import HIServices

    if not bool(HIServices.AXIsProcessTrusted()):
        print(
            "Este proceso no tiene permiso de Accesibilidad.\n"
            "Lanzalo desde Terminal: el permiso es de Terminal, no de Claude.",
            file=sys.stderr,
        )
        return 1

    robot = make_robot_from_config(
        SOFollowerRobotConfig(
            port=PUERTO,
            id=BRAZO,
            max_relative_target=12.0,
            disable_torque_on_disconnect=False,  # que no se desplome al salir
            cameras={},
        )
    )
    teleop = make_teleoperator_from_config(TecladoArticularConfig())
    tuberia = RobotProcessorPipeline[tuple[dict, dict], dict](
        steps=[DeltaAPosicion()],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )

    robot.connect()
    teleop.connect()
    ayuda()

    temperatura, ultima_lectura, pico, motivo = 0, 0.0, 0, "Esc"
    periodo = 1.0 / FPS
    try:
        while teleop.is_connected:
            ciclo = time.perf_counter()

            obs = robot.get_observation()
            robot.send_action(tuberia((teleop.get_action(), obs)))

            if ciclo - ultima_lectura > CADA_S:
                ultima_lectura = ciclo
                # Mediana de tres: una lectura suelta del bus puede venir
                # corrupta, y de este numero depende parar o seguir.
                lecturas = []
                for _ in range(3):
                    try:
                        lecturas.append(
                            int(robot.bus.read("Present_Temperature", VIGILADO, normalize=False))
                        )
                    except Exception:
                        pass
                if lecturas:
                    temperatura = sorted(lecturas)[len(lecturas) // 2]
                    pico = max(pico, temperatura)

            if temperatura >= PARADA_C:
                motivo = f"{VIGILADO} a {temperatura} C"
                break

            marca = "  CALIENTE" if temperatura >= AVISO_C else ""
            posturas = "  ".join(
                f"{k.removesuffix('.pos')[:5]}:{v:6.1f}" for k, v in sorted(obs.items())
            )
            print(f"\r  {temperatura:2d}C{marca}  {posturas}   ", end="", flush=True)

            espera = periodo - (time.perf_counter() - ciclo)
            if espera > 0:
                time.sleep(espera)
    except KeyboardInterrupt:
        motivo = "Ctrl-C"
    finally:
        print()
        teleop.disconnect()
        robot.disconnect()  # con el par PUESTO, por la config de arriba

    print(f"\nFin ({motivo}). Pico de temperatura: {pico} C.")
    print("El brazo sigue SUJETO por los servos: al salir no se cae.")
    print("Para dejarlos libres cuando termines:")
    print("    python scripts/soltar_servos.py")
    if temperatura >= PARADA_C:
        print(
            f"\nSe paro por calor. Dejalo enfriar por debajo de {AVISO_C} C antes de\n"
            "seguir. Si lo vas a tener mucho rato encendido, bajalo apoyado en la\n"
            "mesa: lo que calienta es el hombro sosteniendo el brazo en alto."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
