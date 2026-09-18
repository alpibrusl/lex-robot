"""Teleoperacion por teclado en espacio ARTICULAR: una pareja de teclas por servo.

Por que no el teclado cartesiano que trae lerobot: `keyboard_ee` emite
delta_x/delta_y/delta_z/gripper, pero `so101_follower` solo acepta claves
`<motor>.pos` (filtra por `.endswith(".pos")`). Sin nadie que traduzca, el
diccionario llega VACIO al bus y `sync_write` revienta con StopIteration.
La traduccion existe (InverseKinematicsEEToJoints) pero necesita un URDF que
no viene en el paquete, y ademas da 4 mandos para 5 ejes: la muñeca la elige
la cinematica inversa, no tu.

Aqui cada servo es tuyo. Distribucion sistematica: fila de arriba suma,
fila de casa resta, de izquierda a derecha es de la base a la pinza.

    w/s  shoulder_pan     girar la base
    e/d  shoulder_lift    subir/bajar el hombro
    t/g  elbow_flex       codo
    y/h  wrist_flex       muñeca arriba/abajo
    u/j  wrist_roll       girar la muñeca
    i/k  gripper          abrir/cerrar

Se combinan pulsando a la vez: e+t sube hombro y codo en el mismo fotograma.
Mantener shift mueve a un cuarto de velocidad, para el agarre fino.

OJO con las teclas libres: lerobot-record monta SU PROPIO escucha de teclado
para pasar de episodio, y con pynput los dos escuchas reciben todas las
pulsaciones. Estas estan cogidas y no se pueden usar para mover el brazo:

    n / flecha derecha   dar el episodio por bueno y pasar al siguiente
    r / flecha izquierda repetir el episodio
    q / esc              salir

Por eso el mapa se salta la columna r/f y no empieza en q: girar la base
habria cerrado el programa.
"""

from dataclasses import dataclass, field

from lerobot.configs.types import FeatureType, PipelineFeatureType, PolicyFeature
from lerobot.processor import ProcessorStepRegistry, RobotActionProcessorStep, TransitionKey
from lerobot.teleoperators.config import TeleoperatorConfig
from lerobot.teleoperators.keyboard.configuration_keyboard import KeyboardTeleopConfig
from lerobot.teleoperators.keyboard.teleop_keyboard import KeyboardTeleop

# Unidades normalizadas por fotograma. A 30 fps, 0.7 son 21 unidades/segundo
# sobre un recorrido de 200: barrido completo en ~9 s. La muñeca va mas suelta
# porque mueve poca masa; el hombro mas lento porque carga con todo el brazo.
PASOS = {
    "shoulder_pan": 0.7,
    "shoulder_lift": 0.6,
    "elbow_flex": 0.7,
    "wrist_flex": 0.9,
    "wrist_roll": 1.2,
    "gripper": 1.5,
}

# Reservadas por lerobot-record: n, r, q, esc y las flechas. Ver el docstring.
RESERVADAS = frozenset({"n", "r", "q"})

TECLAS = {
    "w": ("shoulder_pan", +1), "s": ("shoulder_pan", -1),
    "e": ("shoulder_lift", +1), "d": ("shoulder_lift", -1),
    "t": ("elbow_flex", +1), "g": ("elbow_flex", -1),
    "y": ("wrist_flex", +1), "h": ("wrist_flex", -1),
    "u": ("wrist_roll", +1), "j": ("wrist_roll", -1),
    "i": ("gripper", +1), "k": ("gripper", -1),
}

assert not (RESERVADAS & TECLAS.keys()), "una tecla de mover chocaria con lerobot-record"

# El follower normaliza todo a -100..100 menos la pinza, que va de 0 a 100.
LIMITES = {"gripper": (0.0, 100.0)}
LIMITE_POR_DEFECTO = (-100.0, 100.0)

FINO = 0.25  # multiplicador con shift


@TeleoperatorConfig.register_subclass("teclado_articular")
@dataclass
class TecladoArticularConfig(KeyboardTeleopConfig):
    escala: float = 1.0  # sube o baja la velocidad de todos los ejes a la vez


class TecladoArticular(KeyboardTeleop):
    """Emite `<motor>.delta`: cuanto quiere moverse cada eje en este fotograma.

    Deliberadamente NO emite `.pos`: un teclado no sabe donde esta el brazo.
    Convertir el deseo en una posicion absoluta es trabajo de DeltaAPosicion,
    que si ve la observacion real.
    """

    config_class = TecladoArticularConfig
    name = "teclado_articular"

    def __init__(self, config: TecladoArticularConfig):
        super().__init__(config)
        self.config = config

    @property
    def action_features(self) -> dict[str, type]:
        return {f"{m}.delta": float for m in PASOS}

    @property
    def feedback_features(self) -> dict[str, type]:
        return {}

    def get_action(self) -> dict[str, float]:
        self._drain_pressed_keys()
        pulsadas = {k for k, v in self.current_pressed.items() if v}

        fino = any(getattr(k, "name", "") in ("shift", "shift_r") for k in pulsadas)
        escala = self.config.escala * (FINO if fino else 1.0)

        accion = {f"{m}.delta": 0.0 for m in PASOS}
        for tecla in pulsadas:
            if not isinstance(tecla, str):
                continue
            destino = TECLAS.get(tecla.lower())
            if destino is None:
                continue
            motor, signo = destino
            # Sumar, no asignar: q y a a la vez se anulan, que es lo esperable.
            accion[f"{motor}.delta"] += signo * PASOS[motor] * escala
        return accion

    def send_feedback(self, feedback: dict[str, float]) -> None:
        pass


@ProcessorStepRegistry.register("delta_a_posicion")
@dataclass
class DeltaAPosicion(RobotActionProcessorStep):
    """Integra los deltas del teclado sobre la posicion real del brazo.

    Dos decisiones que importan:

    1. Mantiene un objetivo propio en vez de mandar `posicion_actual + delta`.
       Si mandara eso, al soltar las teclas el delta seria 0 y el objetivo
       seria la posicion actual: la gravedad hunde el hombro un poco, el
       objetivo le sigue, y el brazo cae solo escalon a escalon.

    2. Ese objetivo no puede alejarse mas de `margen` de donde esta el brazo.
       Si la pinza topa con la mesa y sigues pulsando, sin este tope el
       objetivo se dispara, el error crece y el servo entra en sobrecarga.
       Con el tope, topar es inofensivo: empuja suave y se queda ahi.
    """

    margen: float = 8.0
    objetivo: dict[str, float] | None = field(default=None, init=False, repr=False)

    def action(self, action):
        obs = self.transition.get(TransitionKey.OBSERVATION) or {}
        actual = {k.removesuffix(".pos"): float(v) for k, v in obs.items() if k.endswith(".pos")}

        if not actual:
            if self.objetivo:
                return {f"{m}.pos": p for m, p in self.objetivo.items()}
            raise RuntimeError(
                "No llega la posicion del brazo en la observacion; sin eso no se "
                "puede convertir el teclado en ordenes. Revisa que el robot este "
                "conectado antes de grabar."
            )

        if self.objetivo is None:
            self.objetivo = dict(actual)  # arrancar donde este, sin saltos

        salida = {}
        for motor, posicion in actual.items():
            objetivo = self.objetivo.get(motor, posicion) + float(action.get(f"{motor}.delta", 0.0))
            bajo, alto = LIMITES.get(motor, LIMITE_POR_DEFECTO)
            objetivo = min(max(objetivo, bajo), alto)
            objetivo = min(max(objetivo, posicion - self.margen), posicion + self.margen)
            self.objetivo[motor] = objetivo
            salida[f"{motor}.pos"] = objetivo
        return salida

    def transform_features(self, features):
        # El teclado aporta deseos (.delta); lo que acaba en el conjunto de
        # datos son posiciones (.pos), que es lo que la politica debera predecir.
        for motor in PASOS:
            features[PipelineFeatureType.ACTION].pop(f"{motor}.delta", None)
            features[PipelineFeatureType.ACTION][f"{motor}.pos"] = PolicyFeature(
                type=FeatureType.ACTION, shape=(1,)
            )
        return features

    def reset(self):
        # Entre episodios recolocas el brazo a mano. Si el objetivo siguiera
        # latcheado del episodio anterior, el primer fotograma del siguiente
        # tiraria de el hacia la pose vieja.
        self.objetivo = None
