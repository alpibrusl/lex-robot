"""Graba demostraciones con el teclado articular.

Hace falta un lanzador propio por dos motivos:

1. lerobot resuelve `--teleop.type=` mirando un registro que se llena al
   importar. Nuestro teleoperador vive fuera del paquete, asi que alguien
   tiene que importarlo antes de que el parser lea los argumentos.

2. `lerobot-record` monta tuberias IDENTIDAD por defecto. Nuestro teclado
   emite deltas, no posiciones, y quien los convierte es DeltaAPosicion.
   Esa pieza solo se puede meter por codigo, pasandosela a record().

Acepta los mismos flags que `lerobot-record`; se los pasa tal cual.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from lerobot.processor import (  # noqa: E402
    RobotProcessorPipeline,
    robot_action_observation_to_transition,
    transition_to_robot_action,
)
from lerobot.scripts.lerobot_record import record  # noqa: E402

from teclado_articular import TECLAS, DeltaAPosicion, TecladoArticular  # noqa: E402,F401

ESPERA_TECLA_S = 20


def teclado_responde(segundos: int = ESPERA_TECLA_S) -> bool:
    """Comprobar que macOS nos deja leer el teclado, ANTES de grabar nada.

    No es paranoia: si falta el permiso de Accesibilidad, lerobot escribe un
    aviso y sigue adelante produciendo cero acciones. Grabarias los episodios
    enteros con el brazo quieto y solo lo descubririas al entrenar.
    Y en macOS no se puede saber de otra forma: el permiso solo se confirma
    cuando un escucha real recibe una tecla.
    """
    try:
        from pynput import keyboard
    except ImportError:
        print("Falta pynput:  pip install pynput", file=sys.stderr)
        return False

    recibida = []
    with keyboard.Listener(on_press=lambda k: (recibida.append(k), False)[1]) as escucha:
        print(f"\nPulsa cualquier tecla para comprobar el permiso ({segundos} s)...", flush=True)
        escucha.join(timeout=segundos)

    if recibida:
        print("Teclado OK.\n", flush=True)
        return True

    print(
        "\nNo llega ninguna tecla. Falta el permiso de Accesibilidad.\n"
        "  Ajustes > Privacidad y seguridad > Accesibilidad\n"
        "  Añade Terminal (Aplicaciones/Utilidades) con el +, activalo,\n"
        "  y CIERRA Y REABRE Terminal para que lo coja.\n"
        "Sin esto lerobot no avisa: grabaria los episodios vacios.",
        file=sys.stderr,
    )
    return False


def ayuda_teclas() -> None:
    print("  Fila de arriba SUMA, fila de casa RESTA, de la base a la pinza:")
    for arriba, abajo in (("q", "a"), ("w", "s"), ("e", "d"), ("r", "f"), ("t", "g"), ("y", "h")):
        print(f"    {arriba} / {abajo}   {TECLAS[arriba][0]}")
    print("  Se combinan pulsando a la vez.  Shift = cuarto de velocidad (agarre fino).")
    print("  Flecha derecha = terminar episodio,  Esc = salir.\n")


def main() -> int:
    if "--saltar-prueba" in sys.argv:
        sys.argv.remove("--saltar-prueba")
    elif not teclado_responde():
        return 1

    ayuda_teclas()

    tuberia = RobotProcessorPipeline[tuple[dict, dict], dict](
        steps=[DeltaAPosicion()],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )
    record(teleop_action_processor=tuberia)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
