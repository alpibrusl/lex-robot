"""Cada test aquí fija un fallo que ocurrió de verdad en este robot.

Ninguno necesita microfono, Ollama ni brazo: la logica pura esta separada del
I/O justamente para poder fijarla sin hardware.
"""
import pytest

from voice_control import (ARTICULACIONES, GRADOS_MAX, JUNTAS, Brazo, delta_ticks,
                           ejecuta, frase, grados_pedidos, ultimo_json, valida)

BRAZOS = ("derecho", "izquierdo")


# ── el JSON que llega sucio ──────────────────────────────────────────────────

def test_extrae_el_json_aunque_el_modelo_anteponga_basura():
    # Respuestas LITERALES de qwen3.8: escupe tokens sueltos antes del JSON, y
    # json.loads sobre la cadena entera falla en todas ellas.
    assert ultimo_json('accion":"{"accion":"pinza","estado":"abrir"}') == {
        "accion": "pinza", "estado": "abrir"}
    assert ultimo_json('accion":"par{"accion":"parar"}') == {"accion": "parar"}
    assert ultimo_json('accion{"accion":"mover","articulacion":"base"}')["articulacion"] == "base"


def test_sin_json_devuelve_none_en_vez_de_reventar():
    assert ultimo_json("lo siento, no entiendo") is None
    assert ultimo_json("") is None
    assert ultimo_json(None) is None


def test_se_queda_con_el_ultimo_objeto_no_el_primero():
    # El prefijo basura a veces ES un objeto parseable; el bueno es el ultimo.
    assert ultimo_json('{"accion":"nada"} {"accion":"parar"}') == {"accion": "parar"}


# ── no adivinar el brazo ─────────────────────────────────────────────────────

def test_sin_brazo_se_pregunta_en_vez_de_elegir_uno():
    """El fallo que lo motiva: se dijo "abre la pinza izquierda" y se abrio la
    DERECHA, porque el ejecutor solo conocia un brazo y se comio el adjetivo.
    Mover el brazo equivocado sin avisar es peor que no moverse."""
    ok, motivo = valida({"accion": "pinza", "brazo": None, "estado": "abrir"}, BRAZOS)
    assert not ok
    assert "que brazo" in motivo


def test_un_brazo_inventado_tambien_se_rechaza():
    ok, motivo = valida({"accion": "pinza", "brazo": "central", "estado": "abrir"}, BRAZOS)
    assert not ok and "que brazo" in motivo


def test_parar_no_necesita_brazo():
    # Parar los DOS siempre es la interpretacion segura de "para".
    ok, _ = valida({"accion": "parar"}, BRAZOS)
    assert ok


# ── rechazar lo que no es una orden ──────────────────────────────────────────

@pytest.mark.parametrize("plan", [
    {"accion": "nada"},                                    # "que tiempo hace hoy"
    None,                                                  # el modelo no devolvio JSON
    {"accion": "bailar", "brazo": "derecho"},
    {"accion": "pinza", "brazo": "derecho", "estado": "girar"},
    {"accion": "mover", "brazo": "derecho", "articulacion": "rodilla", "sentido": "+"},
    {"accion": "mover", "brazo": "derecho", "articulacion": "codo", "sentido": "arriba"},
])
def test_rechaza_lo_que_no_puede_ejecutar(plan):
    ok, motivo = valida(plan, BRAZOS)
    assert not ok and motivo


# ── grados acotados ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("pedido,esperado", [
    (20, 20.0), (0, 1.0), (-5, 1.0), (400, GRADOS_MAX), (None, 15.0), ("mucho", 15.0),
])
def test_los_grados_se_acotan(pedido, esperado):
    # Un modelo puede pedir 400 grados; el brazo no tiene 400 grados que dar.
    assert grados_pedidos({"grados": pedido}) == esperado


def test_el_sentido_decide_el_signo_de_los_ticks():
    mas = delta_ticks({"grados": 30, "sentido": "+"})
    menos = delta_ticks({"grados": 30, "sentido": "-"})
    assert mas > 0 and menos < 0 and mas == -menos


# ── el brazo: un objetivo, no troceado ───────────────────────────────────────

class BusFalso:
    """Registra las escrituras. Un servo que se mueve 40 ticks por lectura."""

    def __init__(self, inicio=2000, avance=40, atascado=False):
        self.p = {j: inicio for j in JUNTAS}
        self.avance, self.atascado = avance, atascado
        self.objetivos = []
        self.par = {j: 0 for j in JUNTAS}

    def sync_read(self, reg, normalize=True):
        return {j: (800 if reg == "Min_Position_Limit" else 3400) for j in JUNTAS}

    def read(self, reg, j, normalize=True):
        if reg != "Present_Position":
            return 0
        if not self.atascado and self.objetivos:
            d = self.objetivos[-1][1] - self.p[j]
            self.p[j] += max(-self.avance, min(self.avance, d))
        return self.p[j]

    def write(self, reg, j, v, normalize=True):
        if reg == "Goal_Position":
            self.objetivos.append((j, v))
        elif reg == "Torque_Enable":
            self.par[j] = v

    def sync_write(self, reg, vals, normalize=True):
        if reg == "Torque_Enable":
            self.par.update(vals)


def test_al_servo_se_le_da_el_objetivo_entero():
    """Trocear de 25 en 25 tardaba 19 s en mover el hombro 20 grados y ademas
    lo hacia parecer atascado. El servo interpola solo: un objetivo basta."""
    bus = BusFalso()
    br = Brazo(bus)
    llego, _ = br.va_a("shoulder_lift", 2300)
    assert llego
    destinos = [v for j, v in bus.objetivos if j == "shoulder_lift"]
    # el primero sincroniza objetivo con la posicion actual antes de dar par
    assert destinos[0] == 2000
    assert destinos[1:] == [2300], f"se troceo el movimiento: {destinos}"


def test_el_objetivo_se_recorta_a_los_limites_del_servo():
    bus = BusFalso()
    br = Brazo(bus)
    br.va_a("elbow_flex", 99999)
    assert max(v for j, v in bus.objetivos if j == "elbow_flex") == 3400 - 20


def test_un_atasco_tiene_que_persistir():
    """Una sola lectura sin avance es transito o un hipo del bus, no un tope.
    Confundirlos hizo pasar por averiado a un hombro que estaba perfecto."""
    bus = BusFalso(atascado=True)
    br = Brazo(bus)
    llego, _ = br.va_a("shoulder_lift", 2600, espera=3.0, quieto_max=4)
    assert not llego


def test_parar_suelta_los_dos_brazos():
    brazos = {"derecho": Brazo(BusFalso()), "izquierdo": Brazo(BusFalso())}
    r = ejecuta({"accion": "parar"}, brazos)
    assert "dos brazos" in r
    for b in brazos.values():
        assert all(v == 0 for v in b.bus.par.values())


def test_una_orden_valida_llega_al_bus():
    brazos = {"derecho": Brazo(BusFalso()), "izquierdo": Brazo(BusFalso())}
    r = ejecuta({"accion": "mover", "brazo": "derecho", "articulacion": "codo",
                 "sentido": "+", "grados": 10}, brazos)
    assert "derecho/elbow_flex" in r
    assert brazos["derecho"].bus.objetivos, "no se escribio nada"
    assert not brazos["izquierdo"].bus.objetivos, "se movio el brazo que no era"


# ── lo que se dice en voz alta ───────────────────────────────────────────────

def test_lo_que_no_se_ejecuta_se_explica_hablando():
    # Una orden que no pasa nada y no dice por que es indistinguible de un
    # robot averiado.
    assert frase({"accion": "pinza"}, "que brazo? di 'derecho'...") == "que brazo?"
    assert frase({"accion": "mover"}, "derecho/elbow_flex topo en 900") == "no puedo, ha topado"


def test_no_se_habla_cuando_no_era_una_orden():
    assert frase({"accion": "nada"}, "(no es una orden)") is None


# ── nivel de entrada ─────────────────────────────────────────────────────────

def test_normaliza_sube_el_audio_flojo_a_un_nivel_util():
    """Medido: con el PowerConf S330 la voz llega a rms 0.0034, y whisper sobre
    audio asi de flojo devolvia "!Suscribete!" en vez de la orden."""
    np = pytest.importorskip("numpy")
    from voice_control import RMS_OBJETIVO, normaliza
    flojo = (np.random.default_rng(0).standard_normal(16000) * 0.0034).astype("float32")
    salida, rms_original = normaliza(flojo)
    assert rms_original == pytest.approx(0.0034, rel=0.2)
    assert float(np.sqrt((salida ** 2).mean())) == pytest.approx(RMS_OBJETIVO, rel=0.2)


def test_normaliza_no_amplifica_el_silencio_sin_limite():
    # Sin tope, un fondo de 1e-9 se convertiria en ruido a todo volumen.
    np = pytest.importorskip("numpy")
    from voice_control import normaliza
    casi_nada = (np.random.default_rng(1).standard_normal(16000) * 1e-7).astype("float32")
    salida, _ = normaliza(casi_nada)
    assert float(np.abs(salida).max()) < 0.01


def test_normaliza_aguanta_el_silencio_absoluto():
    np = pytest.importorskip("numpy")
    from voice_control import normaliza
    salida, rms = normaliza(np.zeros(1000, dtype="float32"))
    assert rms == 0.0 and not np.isnan(salida).any()


def test_hablar_espera_a_terminar_por_defecto(monkeypatch):
    """Sin esto el bucle graba mientras suena la respuesta y el micro se oye a
    si mismo -- aqui el micro y el altavoz son el mismo aparato."""
    import voice_control
    llamadas = []
    monkeypatch.setattr(voice_control.subprocess, "run",
                        lambda *a, **k: llamadas.append(("run", a)))
    monkeypatch.setattr(voice_control.subprocess, "Popen",
                        lambda *a, **k: llamadas.append(("popen", a)))
    voice_control.habla("hecho", "Paulina")
    assert llamadas and llamadas[0][0] == "run", "no espero a terminar de hablar"


def test_no_hablar_no_lanza_proceso(monkeypatch):
    import voice_control
    llamadas = []
    monkeypatch.setattr(voice_control.subprocess, "run", lambda *a, **k: llamadas.append(a))
    voice_control.habla(None, "Paulina")
    voice_control.habla("hecho", "")
    assert not llamadas


# ── palabra de activacion ────────────────────────────────────────────────────

def test_la_palabra_clave_deja_pasar_la_orden():
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave("robot abre la pinza derecha") == "abre la pinza derecha"


def test_sin_palabra_clave_se_ignora():
    """"Y cortero volando" -- conversacion de fondo que el robot procesaba."""
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave("y cortero volando") is None
    assert tras_palabra_clave("abre la pinza derecha") is None


@pytest.mark.parametrize("oido", ["robo abre la pinza", "roboc abre la pinza",
                                  "Robot, abre la pinza", "ROBOT abre la pinza"])
def test_tolera_que_la_transcripcion_escriba_mal_la_clave(oido):
    # Whisper escribe "robot" de varias formas segun la pronunciacion; exigir
    # la palabra exacta rechazaria ordenes buenas.
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave(oido) == "abre la pinza"


def test_la_clave_solo_cuenta_al_principio():
    """Aceptarla en cualquier posicion dejaria que una frase de fondo que
    mencione 'robot' de pasada disparase lo que venga detras."""
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave("pues mira lo que hace el nuevo robot abre la pinza") is None


def test_la_clave_sola_no_es_una_orden():
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave("robot") is None


def test_clave_vacia_atiende_todo():
    from voice_control import tras_palabra_clave
    assert tras_palabra_clave("abre la pinza", clave="") == "abre la pinza"


# ── ruedas ───────────────────────────────────────────────────────────────────

def test_las_direcciones_validas_pasan_sin_pedir_brazo():
    # La base es una sola, no hay "base derecha" ni "base izquierda".
    from voice_control import valida
    for d in ("adelante", "atras", "izquierda", "derecha"):
        ok, motivo = valida({"accion": "base", "direccion": d}, BRAZOS)
        assert ok, motivo


def test_una_direccion_inventada_se_rechaza():
    from voice_control import valida
    ok, motivo = valida({"accion": "base", "direccion": "arriba"}, BRAZOS)
    assert not ok and "direccion" in motivo


@pytest.mark.parametrize("pedido,esperado", [
    (0.5, 0.5), (0.05, 0.2), (99, 1.5), (None, 0.5), ("mucho", 0.5),
])
def test_las_rafagas_de_ruedas_se_acotan(pedido, esperado):
    """Cortas a proposito: este robot va ATADO POR USB al ordenador, asi que
    rodar de mas arrastra los cables."""
    from voice_control import segundos_base
    assert segundos_base({"segundos": pedido}) == esperado


def test_adelante_manda_signos_OPUESTOS_a_las_dos_ruedas():
    """Estan montadas en espejo: medido en el suelo, las dos positivas hacen
    girar el robot sobre si mismo en vez de avanzar."""
    from voice_control import DIRECCIONES, RUEDA_SIGNO
    izq, der = DIRECCIONES["adelante"]
    assert (izq * RUEDA_SIGNO["izq"]) * (der * RUEDA_SIGNO["der"]) < 0


def test_girar_manda_el_MISMO_signo_a_las_dos():
    from voice_control import DIRECCIONES, RUEDA_SIGNO
    izq, der = DIRECCIONES["izquierda"]
    assert (izq * RUEDA_SIGNO["izq"]) * (der * RUEDA_SIGNO["der"]) > 0


def test_las_ruedas_siempre_se_paran_aunque_algo_falle():
    """Una rueda que se queda girando no tiene quien la pare."""
    from voice_control import Brazo, ejecuta
    br = Brazo(BusFalso())
    ordenes = []
    br.rueda = lambda ident, v: ordenes.append((ident, v))
    def revienta(*a, **k):
        raise RuntimeError("bus caido")
    import voice_control
    original = voice_control.time.sleep
    voice_control.time.sleep = revienta
    try:
        with pytest.raises(RuntimeError):
            ejecuta({"accion": "base", "direccion": "adelante"}, {"derecho": br})
    finally:
        voice_control.time.sleep = original
    assert ordenes[-2:] == [(9, 0.0), (10, 0.0)], f"no se pararon: {ordenes}"


def test_las_frases_habladas_son_cortas():
    """El tiempo de `say` es el de PRONUNCIAR: 5 caracteres 1.12 s, 51 caracteres
    3.91 s. Como hablar bloquea la escucha, cada palabra de mas es latencia."""
    from voice_control import frase
    for plan in ({"accion": "pinza", "brazo": "derecho", "estado": "abrir"},
                 {"accion": "mover", "brazo": "izquierdo", "articulacion": "hombro"},
                 {"accion": "base", "direccion": "adelante"}):
        assert len(frase(plan, "ok")) <= 12, frase(plan, "ok")
