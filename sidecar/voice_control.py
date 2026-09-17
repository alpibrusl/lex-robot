#!/usr/bin/env python3
"""Ordenes habladas -> movimiento del brazo, todo en local.

    micro -> faster-whisper -> un LLM de Ollama -> escritura en el bus de servos

Nada de esto sale de la maquina: whisper transcribe en local y al modelo solo le
llega el TEXTO, nunca el audio. Es la misma postura que ya toma el skill
`listen` del sidecar, y la razon de que la voz sea utilizable en una casa.

QUE ENTIENDE, Y QUE NO

Mueve articulaciones y abre o cierra la pinza, en cualquiera de los dos brazos.
NO agarra objetos: sin extrinsecos de camara ni politica entrenada eso no
existe todavia en este robot, y ofrecerlo por voz seria prometer lo que no hay.

TRES COSAS QUE COSTO APRENDER, TODAS MEDIDAS EN ESTA UNIDAD

1. El modelo antepone tokens sueltos al JSON ('accion":"{"accion":"pinza"...'),
   asi que se busca el ULTIMO objeto que parsee en vez de fiarse de la cadena.

2. Si no dicen que brazo, se PREGUNTA. Elegir uno por defecto movia el brazo
   equivocado sin avisar -- se dijo "abre la pinza izquierda" y se abrio la
   derecha. Un fallo silencioso es peor que una pregunta.

3. Al servo se le da el objetivo ENTERO y el interpola. Trocearlo de 25 en 25
   ticks esperando la llegada de cada paso tardaba 19 s en mover el hombro 20
   grados, y ademas lo hacia parecer atascado; de una vez tarda 0,5 s.

SOBRE EL MODELO: en Apple Silicon el runtime pesa mas que el tamano. Medido
aqui, qwen3.8:27b-mlx responde en 4,8 s de media y acierta 7/7, mientras que
granite4.2:3b -- ocho veces mas pequeno -- tarda 9,8 s y falla una. Elegir el
modelo pequeno "porque sera mas rapido" es exactamente al reves.

    python sidecar/voice_control.py                 # escucha y ejecuta
    python sidecar/voice_control.py --texto "abre la pinza derecha"
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.request

ARTICULACIONES = {
    "base": "shoulder_pan", "hombro": "shoulder_lift", "codo": "elbow_flex",
    "muneca_inclinar": "wrist_flex", "muneca_girar": "wrist_roll",
}
JUNTAS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
GRADOS_MAX = 40.0

# Ruedas: ids 9 y 10 sobre el bus del brazo DERECHO, en modo velocidad.
# Estan MONTADAS EN ESPEJO, asi que "adelante" NO es el mismo signo en las dos:
# medido en el suelo, izquierda negativa y derecha positiva avanza. Mandarlas
# las dos positivas hace girar el robot sobre si mismo.
RUEDA_IZQ, RUEDA_DER = 9, 10
RUEDA_SIGNO = {"izq": -1, "der": +1}          # multiplican a "adelante"
RUEDA_GRADOS_S = float(os.environ.get("LEX_VOZ_RUEDA_DPS", "70"))
RUEDA_SEG_MAX = float(os.environ.get("LEX_VOZ_RUEDA_SEG_MAX", "1.5"))
DIRECCIONES = {                                # (izq, der) como fraccion
    "adelante": (1, 1), "atras": (-1, -1), "izquierda": (-1, 1), "derecha": (1, -1),
}
TICKS_POR_GRADO = 4096 / 360

SISTEMA = """Traduces ordenes habladas a un robot de DOS BRAZOS a JSON. Responde SOLO JSON, sin texto.

Brazos: "derecho", "izquierdo". Si no lo dicen, pon "brazo":null.
Articulaciones validas: base, hombro, codo, muneca_inclinar, muneca_girar
Formatos:
  {"accion":"mover","brazo":"derecho"|"izquierdo"|null,"articulacion":"<valida>","sentido":"+"|"-","grados":<1-40>}
  {"accion":"pinza","brazo":"derecho"|"izquierdo"|null,"estado":"abrir"|"cerrar"}
  {"accion":"base","direccion":"adelante"|"atras"|"izquierda"|"derecha","segundos":<0.2-1.5>}
  {"accion":"parar"}
  {"accion":"mirar","direccion":"frente"|"derecha"|"izquierda"|"cerca","pregunta":"<lo que preguntan>"}
  {"accion":"nada"}

"+" = base a la derecha, hombro arriba, codo estira, muneca arriba, giro horario.
Si no dicen cuanto, usa 15 grados.
"base" mueve el ROBOT ENTERO sobre sus ruedas ("avanza", "ve hacia atras",
"gira a la izquierda"); si no dicen cuanto, usa 0.5 segundos.
"articulacion":"base" es otra cosa: el giro del hombro de un brazo.
"mirar" es para PREGUNTAS sobre lo que ve, no ordenes de movimiento: "que ves",
"donde estas", "que hay a la derecha", "hay alguien". Copia la pregunta tal cual
en "pregunta". "direccion" es hacia donde mirar: "frente" por defecto, y "cerca"
si piden mirar de cerca lo que tiene en la pinza.
La transcripcion puede traer erratas ("pinta" por "pinza"): interpreta la intencion."""

# El reconocedor se sesga hacia este vocabulario. Sin el, "hombro" se
# transcribia como "el nombre de" y el plan salia {"accion":"nada"} -- con
# razon, porque eso no es una orden.
PROMPT_ASR = ("Ordenes a un robot de dos brazos: hombro, codo, muneca, pinza, base, "
              "brazo derecho, brazo izquierdo, abre, cierra, sube, baja, gira, para, grados.")

# Umbral de "aqui hay voz". Medido en esta casa con un Anker PowerConf S330:
# hablando normal da rms 0.0034, y con 0.004 el bucle lo tiraba como silencio en
# CADA intento. Esos micros de conferencia llevan ganancia automatica y atenuan
# fuerte cuando creen que no hay nadie cerca, asi que el umbral tiene que ir
# bien por debajo de lo que parece razonable.
RMS_MINIMO = float(os.environ.get("LEX_VOZ_RMS_MIN", "0.001"))
RMS_OBJETIVO = 0.05

# Palabra de activacion. Sin ella el robot procesa TODO lo que oye: una
# conversacion de fondo dio "Y cortero volando", y peor, se llego a oir a si
# mismo y a transcribir su propia respuesta pegada a una orden humana.
PALABRA_CLAVE = os.environ.get("LEX_VOZ_CLAVE", "handi").lower()
# Variantes ACEPTADAS explicitamente. La distancia de edicion sola no basta:
# con tolerancia 2 sobre una palabra de 5 letras se cuela casi cualquier cosa,
# y subirla para admitir "jandi" abriria aun mas la puerta. Whisper escribe los
# nombres propios segun le suenan, asi que se listan las formas reales que
# produce y se compara exacto contra ellas, dejando la tolerancia para el resto.
VARIANTES = {
    "handi": ("handi", "handy", "jandi", "jandy", "andi", "andy", "handie"),
    "robot": ("robot", "robo", "roboc", "roboh"),
}
# Cuantas letras puede equivocar la transcripcion y seguir contando. Whisper
# escribe "robot" como "robo", "roboc" o "Roberto" segun la pronunciacion, asi
# que una comparacion exacta rechazaria ordenes buenas.
CLAVE_TOLERANCIA = int(os.environ.get("LEX_VOZ_CLAVE_TOLERANCIA", "2"))


def _sin_tildes(t: str) -> str:
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFD", t)
                   if unicodedata.category(c) != "Mn")


def _distancia(a: str, b: str) -> int:
    """Levenshtein. Corto a proposito: solo se compara con una palabra."""
    if len(a) < len(b):
        a, b = b, a
    previa = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        actual = [i]
        for j, cb in enumerate(b, 1):
            actual.append(min(previa[j] + 1, actual[j - 1] + 1,
                              previa[j - 1] + (ca != cb)))
        previa = actual
    return previa[-1]


def tras_palabra_clave(texto: str, clave: str = None, tolerancia: int = None):
    """Lo que viene DESPUES de la palabra de activacion, o None si no esta.

    Se busca en las tres primeras palabras: quien activa dice la clave al
    principio, y aceptarla en cualquier posicion reabriria la puerta a que una
    frase de fondo que la mencione de pasada dispare una orden.
    """
    # `is None`, no `or`: una clave VACIA significa "atiende todo", y con `or`
    # caia al valor por defecto y no habia forma de desactivarla.
    clave = PALABRA_CLAVE if clave is None else clave
    tol = CLAVE_TOLERANCIA if tolerancia is None else tolerancia
    if not clave:
        return texto
    variantes = VARIANTES.get(clave, ())
    # Con variantes explicitas la tolerancia amplia sobra y hace dano: "mandy"
    # esta a distancia 2 de "handi" y activaba el robot en mitad de una
    # conversacion. Las formas que Whisper produce de verdad ya estan listadas,
    # asi que basta 1 para deslices menores.
    if variantes:
        tol = min(tol, 1)
    palabras = _sin_tildes((texto or "").lower()).replace(",", " ").replace(".", " ").split()
    for i, p in enumerate(palabras[:3]):
        if p in variantes or _distancia(p, clave) <= tol:
            resto = " ".join(palabras[i + 1:]).strip()
            return resto or None
    return None


def normaliza(audio):
    """Llevar el audio a un volumen util antes de transcribir.

    Whisper alucina con audio flojo -- devolvia "!Suscribete!" y frases sueltas
    en ingles sobre grabaciones de voz real pero debil. Normalizar quita esa
    dependencia del nivel de entrada, que varia con el micro y la distancia.
    """
    import numpy as np
    rms = float(np.sqrt((audio ** 2).mean()))
    if rms < 1e-9:
        return audio, rms
    ganancia = min(RMS_OBJETIVO / rms, 30.0)     # tope: no amplificar solo ruido
    return np.clip(audio * ganancia, -1.0, 1.0), rms


def ultimo_json(texto: str):
    """El ultimo objeto JSON que parsee dentro de `texto`, o None.

    No es paranoia: los modelos anteponen tokens sueltos al JSON pedido, y
    `json.loads` sobre la cadena entera falla en cada una de esas respuestas.
    """
    for m in reversed(list(re.finditer(r"\{", texto or ""))):
        try:
            return json.loads(texto[m.start():])
        except Exception:
            continue
    return None


def valida(plan: dict, brazos_conocidos) -> tuple[bool, str]:
    """(es_ejecutable, motivo). Rechaza en vez de adivinar.

    El motivo se devuelve para poder decirlo en voz alta: una orden que no se
    ejecuta y no se explica es indistinguible de un robot averiado.
    """
    accion = (plan or {}).get("accion")
    if accion in (None, "nada"):
        return False, "(no es una orden)"
    if accion == "parar":
        return True, ""
    if accion == "base":
        if plan.get("direccion") not in DIRECCIONES:
            return False, f"direccion desconocida: {plan.get('direccion')!r}"
        return True, ""
    if accion not in ("mover", "pinza"):
        return False, f"accion desconocida: {accion!r}"
    brazo = plan.get("brazo")
    if brazo not in brazos_conocidos:
        return False, f"que brazo? di 'derecho' o 'izquierdo' (entendi {brazo!r})"
    if accion == "pinza":
        if plan.get("estado") not in ("abrir", "cerrar"):
            return False, f"estado de pinza desconocido: {plan.get('estado')!r}"
        return True, ""
    if plan.get("articulacion") not in ARTICULACIONES:
        return False, f"articulacion desconocida: {plan.get('articulacion')!r}"
    if plan.get("sentido") not in ("+", "-"):
        return False, f"sentido desconocido: {plan.get('sentido')!r}"
    return True, ""


def grados_pedidos(plan: dict) -> float:
    """Grados acotados a 1..GRADOS_MAX. Un modelo puede pedir 400."""
    try:
        g = float(plan.get("grados", 15))
    except (TypeError, ValueError):
        g = 15.0
    return max(1.0, min(g, GRADOS_MAX))


def delta_ticks(plan: dict) -> int:
    return int(grados_pedidos(plan) * TICKS_POR_GRADO) * (1 if plan.get("sentido") == "+" else -1)


def segundos_base(plan: dict) -> float:
    """Acotado a 0.2-RUEDA_SEG_MAX. Rafagas cortas a proposito: este robot va
    ATADO POR USB al ordenador, asi que rodar de mas arrastra los cables."""
    try:
        s = float(plan.get("segundos", 0.5))
    except (TypeError, ValueError):
        s = 0.5
    return max(0.2, min(s, RUEDA_SEG_MAX))


def frase(plan: dict, resultado: str) -> str | None:
    """Que decir en voz alta. CORTA, y por un motivo medido: el tiempo de `say`
    es el tiempo de PRONUNCIAR la frase, no de generarla -- 5 caracteres son
    1.12 s, 19 son 1.98 s y 51 son 3.91 s. Como hablar bloquea la escucha, cada
    palabra de mas es latencia. Cambiar de motor TTS no arregla esto: nadie dice
    "pinza derecho abrir" mas rapido de lo que se tarda en decirlo."""
    accion = (plan or {}).get("accion")
    if "que brazo" in resultado:
        return "que brazo?"
    if "topo" in resultado:
        return "no puedo, ha topado"
    if accion in (None, "nada"):
        return None
    if accion == "parar":
        return "parado"
    if accion in ("pinza", "mover", "base"):
        return "hecho"
    return None


def planifica(texto: str, modelo: str, url: str = "http://localhost:11434/api/chat",
              timeout=180, pensar: bool = False):
    """Traducir la orden a JSON.

    `think=False` importa MUCHO: qwen3.8 razona por defecto y gastaba entre 192
    y 917 caracteres de pensamiento para decidir que "para" significa parar.
    Medido aqui, desactivarlo baja la media de 4.46 s a 0.92 s -- casi 5x -- con
    resultados IDENTICOS en los cuatro casos probados.

    Y explica la basura que aparecia antes del JSON ('accion":"{"accion"...'):
    eran los tokens de pensamiento filtrandose al contenido. `ultimo_json` los
    esquivaba; esto elimina la causa. Se deja parametrizable porque una tarea
    mas dificil si podria justificar el razonamiento.
    """
    cuerpo = {"model": modelo, "stream": False, "format": "json", "think": pensar,
              "messages": [{"role": "system", "content": SISTEMA},
                           {"role": "user", "content": texto}]}
    req = urllib.request.Request(
        url, data=json.dumps(cuerpo).encode(),
        headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    return ultimo_json(r["message"]["content"])


def voz_disponible(voz: str) -> bool:
    """Si `say -v <voz>` no existe, falla en silencio y no se oye NADA.

    Paso tal cual: se eligio "Monica" y la voz instalada es "Monica" con tilde,
    asi que cada respuesta hablada se perdia sin un solo mensaje de error. Una
    salida silenciosa es indistinguible de un altavoz estropeado, asi que esto
    se comprueba al arrancar y se dice.
    """
    try:
        r = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, timeout=10)
        return any(l.split()[:1] == [voz] for l in r.stdout.splitlines() if l.strip())
    except Exception:
        return False


def habla(texto: str | None, voz: str, espera: bool = True) -> None:
    """`say` de macOS: local, sin dependencias, sin red.

    ESPERA a terminar por defecto, y eso es la parte importante. Hablando en
    segundo plano el bucle volvia a grabar mientras sonaba la respuesta, y el
    micro se oia a si mismo: una ventana capturo "Pinza izquierdo cerrar. Mueve
    atras el hombro derecho" -- su propia respuesta pegada a la orden humana.
    En este equipo el micro y el altavoz son el MISMO aparato (un PowerConf),
    asi que la realimentacion no es teorica; si una respuesta se parece a una
    orden, el robot se manda ordenes a si mismo.
    """
    if not voz or not texto:
        return
    try:
        fn = subprocess.run if espera else subprocess.Popen
        fn(["say", "-v", voz, texto],
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


class Brazo:
    """Un brazo sobre su bus. Envuelve lo justo para que el ejecutor sea
    testeable con un doble: leer, escribir objetivo, dar y quitar par."""

    def __init__(self, bus):
        self.bus = bus
        self.lo = bus.sync_read("Min_Position_Limit", normalize=False)
        self.hi = bus.sync_read("Max_Position_Limit", normalize=False)

    def pos(self, j):
        return self.bus.read("Present_Position", j, normalize=False)

    def rueda(self, ident, grados_s):
        """Velocidad de una rueda en grados/s. Goal_Velocity es SIGNO-MAGNITUD
        en estos servos, no complemento a dos: el bit 15 marca el signo."""
        from lerobot.motors.encoding_utils import encode_sign_magnitude
        from lerobot.motors.motors_bus import get_address
        addr, largo = get_address(self.bus.model_ctrl_table, "sts3215", "Goal_Velocity")
        crudo = int(round(grados_s * 4096.0 / 360.0))
        crudo = max(-32767, min(32767, crudo))
        self.bus._write(addr, largo, ident, encode_sign_magnitude(crudo, 15))

    def suelta(self):
        self.bus.sync_write("Torque_Enable", {j: 0 for j in JUNTAS}, normalize=False)

    def va_a(self, j, destino, espera=6.0, quieto_max=8):
        """Un solo objetivo; el servo interpola. Devuelve (llego, posicion).

        El atasco tiene que persistir `quieto_max` lecturas: una sola lectura
        sin avance es transito o un hipo del bus, no un tope -- confundirlos
        fue lo que hizo pasar por averiado a un hombro que estaba perfecto.
        """
        destino = int(max(self.lo[j] + 20, min(destino, self.hi[j] - 20)))
        origen = self.pos(j)
        self.bus.write("Goal_Position", j, origen, normalize=False)
        self.bus.write("Torque_Enable", j, 1, normalize=False)
        time.sleep(0.15)
        self.bus.write("Goal_Position", j, destino, normalize=False)
        t0, ultimo, quieto = time.time(), origen, 0
        while time.time() - t0 < espera:
            time.sleep(0.12)
            p = self.pos(j)
            if abs(p - destino) <= 20:
                return True, p
            quieto = quieto + 1 if abs(p - ultimo) < 3 else 0
            ultimo = p
            if quieto >= quieto_max:
                return False, p
        return False, self.pos(j)


def mirar(plan: dict) -> str:
    """Responder una pregunta sobre lo que se ve.

    Va aparte de los movimientos a proposito: no toca el bus de servos de los
    brazos, y su modo de fallar es distinto -- una camara a oscuras no da un
    error, da una descripcion inventada. Eso se filtra en vision.captura.
    """
    import vision
    return vision.mira(plan.get("direccion") or "frente", plan.get("pregunta"))


def ejecuta(plan: dict, brazos: dict) -> str:
    ok, motivo = valida(plan, brazos)
    if not ok:
        return motivo
    accion = plan["accion"]
    if accion == "mirar":
        return mirar(plan)
    if accion == "parar":
        for b in brazos.values():
            b.suelta()
        return "PARADO, par quitado en los dos brazos"
    if accion == "base":
        # Las ruedas cuelgan del bus del brazo DERECHO en esta unidad.
        br = brazos["derecho"]
        izq, der = DIRECCIONES[plan["direccion"]]
        seg = segundos_base(plan)
        try:
            br.rueda(RUEDA_IZQ, izq * RUEDA_SIGNO["izq"] * RUEDA_GRADOS_S)
            br.rueda(RUEDA_DER, der * RUEDA_SIGNO["der"] * RUEDA_GRADOS_S)
            time.sleep(seg)
        finally:
            # Parar SIEMPRE, incluso si algo falla a mitad: una rueda que se
            # queda girando no tiene quien la pare.
            br.rueda(RUEDA_IZQ, 0.0)
            br.rueda(RUEDA_DER, 0.0)
        return f"base {plan['direccion']} {seg:.1f}s"
    lado = plan["brazo"]
    br = brazos[lado]
    if accion == "pinza":
        destino = br.hi["gripper"] - 20 if plan["estado"] == "abrir" else br.lo["gripper"] + 20
        antes = br.pos("gripper")
        llego, p = br.va_a("gripper", destino)
        return f"pinza {lado} {plan['estado']} ({antes} -> {p})" + ("" if llego else "  [no llego]")
    j = ARTICULACIONES[plan["articulacion"]]
    antes = br.pos(j)
    llego, p = br.va_a(j, antes + delta_ticks(plan))
    if not llego:
        return f"{lado}/{j} topo en {p}"
    return f"{lado}/{j} {antes} -> {p} ({grados_pedidos(plan):.0f} deg {plan['sentido']})"


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--modelo", default=os.environ.get("LEX_VOZ_MODELO", "qwen3.8:27b-mlx"))
    ap.add_argument("--asr", default=os.environ.get("LEX_VOZ_ASR",
                                                    "mlx-community/whisper-large-v3-turbo"),
                    help="repo de mlx-whisper, o un nombre de faster-whisper con --motor faster")
    ap.add_argument("--motor", choices=["mlx", "faster"],
                    default=os.environ.get("LEX_VOZ_MOTOR", "mlx"),
                    help="mlx: 5.6x mas rapido en Apple Silicon (medido)")
    ap.add_argument("--voz", default=os.environ.get("LEX_VOZ_TTS", "Paulina"),
                    help="voz de `say`; vacio = sin respuesta hablada")
    ap.add_argument("--segundos", type=float, default=6.0)
    ap.add_argument("--clave", default=PALABRA_CLAVE,
                    help="palabra de activacion; vacio = atender todo")
    ap.add_argument("--texto", help="ejecutar esta orden y salir, sin microfono")
    a = ap.parse_args()

    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    puertos = {"derecho": os.environ.get("LEX_XLE_RIGHT_PORT"),
               "izquierdo": os.environ.get("LEX_XLE_LEFT_PORT")}
    faltan = [k for k, v in puertos.items() if not v]
    if faltan:
        raise SystemExit(f"falta LEX_XLE_{faltan[0].upper()}_PORT en el entorno "
                         "(source deploy/mac/xlerobot.env.example)")
    brazos = {}
    for lado, puerto in puertos.items():
        motores = {n: Motor(i + 1, "sts3215", MotorNormMode.RANGE_M100_100)
                   for i, n in enumerate(JUNTAS)}
        bus = FeetechMotorsBus(port=puerto, motors=motores)
        bus.connect()
        brazos[lado] = Brazo(bus)
        print(f"  brazo {lado}: 6/6 en {puerto.split('/')[-1]}", flush=True)
    if a.voz and not voz_disponible(a.voz):
        print(f"  AVISO: la voz {a.voz!r} no existe; no habra respuesta hablada.\n"
              f"         voces disponibles: say -v '?'", flush=True)
    try:
        if a.texto:
            plan = planifica(a.texto, a.modelo)
            print(f"  plan: {plan}\n  -> {ejecuta(plan, brazos)}", flush=True)
            return
        import numpy as np
        import sounddevice as sd
        print(f"cargando {a.motor} '{a.asr}'...", flush=True)
        if a.motor == "mlx":
            # Medido sobre la MISMA grabacion en este Mac: mlx-whisper tarda
            # 0.78 s donde faster-whisper tarda 4.39 s con el mismo modelo
            # `small`, y large-v3-turbo en mlx tarda lo mismo que small (0.80 s)
            # siendo mucho mejor. Mismo patron que con el LLM: en Apple Silicon
            # manda el RUNTIME, no el tamano del modelo.
            import mlx_whisper
            import soundfile as sf

            def transcribe(audio):
                sf.write("/tmp/lex_voz.wav", audio, 16000)
                return mlx_whisper.transcribe(
                    "/tmp/lex_voz.wav", path_or_hf_repo=a.asr,
                    language="es", initial_prompt=PROMPT_ASR)["text"].strip()
        else:
            from faster_whisper import WhisperModel
            modelo_asr = WhisperModel(a.asr, device="cpu", compute_type="int8")

            def transcribe(audio):
                segs, _ = modelo_asr.transcribe(
                    audio, language="es", beam_size=1, initial_prompt=PROMPT_ASR,
                    vad_filter=True, vad_parameters={"min_silence_duration_ms": 300},
                    condition_on_previous_text=False, no_speech_threshold=0.5)
                return " ".join(s.text for s in segs).strip()
        print(f"\n*** LISTO — di \"{a.clave} ...\" cuando veas ESCUCHANDO. Ctrl-C para salir ***", flush=True)
        while True:
            print(f"\nESCUCHANDO ({a.segundos:.0f}s)...", flush=True)
            audio = sd.rec(int(a.segundos * 16000), samplerate=16000, channels=1,
                           dtype="float32")
            sd.wait()
            audio = audio.flatten()
            audio, rms = normaliza(audio)
            if rms < RMS_MINIMO:
                print(f"  (silencio, rms={rms:.5f})", flush=True)
                continue
            texto = transcribe(audio)
            if not texto:
                print("  (sin texto)", flush=True)
                continue
            print(f'  oido: "{texto}"', flush=True)
            orden = tras_palabra_clave(texto, a.clave)
            if orden is None:
                print(f"  (no empieza por '{a.clave}', ignorado)", flush=True)
                continue
            print(f'  orden: "{orden}"', flush=True)
            plan = planifica(orden, a.modelo)
            print(f"  plan: {plan}", flush=True)
            r = ejecuta(plan, brazos)
            print(f"  -> {r}", flush=True)
            habla(frase(plan, r), a.voz)
    except KeyboardInterrupt:
        pass
    finally:
        for b in brazos.values():
            b.suelta()
            b.bus.disconnect(disable_torque=False)
        print("\nsalido, los dos brazos sueltos", flush=True)


if __name__ == "__main__":
    main()
