"""Diagnostico: ver que produce el teclado, sin tocar el robot.

Parte la cadena en dos. Si aqui las teclas aparecen, el problema esta en el
brazo (par, limites, puerto). Si no aparecen, esta en el teclado y no tiene
sentido mirar el robot.

Ejecutalo DESDE TU TERMINAL, no a traves de Claude: el permiso de
Accesibilidad lo tiene Terminal, no el proceso de Claude.
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
from lerobot.teleoperators.utils import make_teleoperator_from_config  # noqa: E402

from teclado_articular import DeltaAPosicion, TecladoArticularConfig  # noqa: E402

SEGUNDOS = 20
# Posicion de mentira, solo para ver que sale por el otro lado de la tuberia.
FALSA = {
    "shoulder_pan.pos": 0.0, "shoulder_lift.pos": 0.0, "elbow_flex.pos": 0.0,
    "wrist_flex.pos": 0.0, "wrist_roll.pos": 0.0, "gripper.pos": 50.0,
}


def main() -> int:
    import HIServices

    confianza = bool(HIServices.AXIsProcessTrusted())
    print(f"permiso de Accesibilidad en ESTE proceso: {confianza}")
    if not confianza:
        print(
            "\nEste proceso no tiene el permiso. Si lo has lanzado desde Claude,\n"
            "lanzalo desde Terminal: el permiso es de Terminal, no de Claude.",
            file=sys.stderr,
        )
        return 1

    teleop = make_teleoperator_from_config(TecladoArticularConfig())
    print(f"teleoperador: {type(teleop).__name__}")
    teleop.connect()
    print(f"escucha vivo: {teleop.is_connected}")

    tuberia = RobotProcessorPipeline[tuple[dict, dict], dict](
        steps=[DeltaAPosicion()],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )

    print(f"\nPulsa teclas durante {SEGUNDOS} s (w/s e/d t/g y/h u/j i/k).")
    print("Solo se imprime cuando algo se mueve.\n")

    fin = time.perf_counter() + SEGUNDOS
    vistas, fotogramas = set(), 0
    while time.perf_counter() < fin:
        accion = teleop.get_action()
        salida = tuberia((accion, FALSA))
        fotogramas += 1
        activos = {k.removesuffix(".delta"): v for k, v in accion.items() if abs(v) > 1e-9}
        if activos:
            vistas.update(activos)
            detalle = "  ".join(f"{m}{v:+.2f}" for m, v in sorted(activos.items()))
            objetivo = "  ".join(
                f"{m.removesuffix('.pos')}={v:.2f}"
                for m, v in sorted(salida.items())
                if abs(v - FALSA[m]) > 1e-9
            )
            print(f"  teclado: {detalle}   ->   brazo: {objetivo or '(sin cambio)'}")
        time.sleep(1 / 30)

    teleop.disconnect()
    print(f"\n{fotogramas} fotogramas leidos.")
    if vistas:
        print(f"FUNCIONA. Ejes que respondieron: {', '.join(sorted(vistas))}")
        print("Si el robot no se movia, el fallo esta en el brazo, no en el teclado.")
        return 0
    print(
        "NINGUNA TECLA LLEGO.\n"
        "  - Lanzado desde Terminal, no desde Claude?\n"
        "  - Estabas pulsando w/s/e/d/t/g/y/h/u/j/i/k (no las flechas)?\n"
        "  - Tenia el foco alguna ventana rara (captura de pantalla, VNC)?",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
