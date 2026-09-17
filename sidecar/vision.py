#!/usr/bin/env python3
"""Responder preguntas sobre lo que el robot VE. Todo en local.

El mismo modelo que ya interpreta las ordenes habladas (qwen3.8:27b-mlx) tiene
capacidad de vision, asi que describir la escena no cuesta ni un modelo mas ni
una descarga: se le manda el fotograma y responde en 2-3 s.

LA PARTE IMPORTANTE ES LO QUE NO SE PREGUNTA. Con la luz apagada, la camara
devuelve una imagen negra y el modelo NO dice "no veo nada": describio con toda
seguridad "una pizarra" que no existia. Una respuesta inventada suena igual de
convincente que una buena, asi que el fotograma se valida ANTES de preguntar.
Medido en esta habitacion: a oscuras el brillo medio queda por debajo de 12, y
con luz entre 84 y 109. Hay margen de sobra.

Para preguntas direccionales ("que hay a la derecha") se gira la torre, se mira
y se VUELVE a la pose de partida. Volver no es cosmetico: los extrinsecos de la
camara estan atados a un angulo concreto, y dejarla mirando a otro lado
invalidaria la calibracion sin avisar.
"""
import base64
import json
import os
import time
import urllib.request

MODELO = os.environ.get("LEX_VOZ_MODELO", "qwen3.8:27b-mlx")
OLLAMA = os.environ.get("LEX_OLLAMA_URL", "http://localhost:11434")
BRILLO_MIN = float(os.environ.get("LEX_VIS_BRILLO_MIN", "12"))
CONTRASTE_MIN = float(os.environ.get("LEX_VIS_CONTRASTE_MIN", "8"))
CAMARAS = {
    "frente": int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "0")),
    "cerca_izq": int(os.environ.get("LEX_XLE_CAMERA_LEFT_INDEX", "1")),
    "cerca_der": int(os.environ.get("LEX_XLE_CAMERA_RIGHT_INDEX", "2")),
}
# Cuanto gira la torre por direccion. 1 tick = 0.088 grados.
GIRO = {"derecha": +1020, "izquierda": -1020,
        "mucho_derecha": +2040, "mucho_izquierda": -2040}


def calidad(frame):
    """(brillo, contraste) de un fotograma, y si sirve para preguntar."""
    import cv2
    g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    br, sd = float(g.mean()), float(g.std())
    return br, sd, (br >= BRILLO_MIN and sd >= CONTRASTE_MIN)


def captura(indice=0, intentos=4, calentar=10):
    """Fotograma VALIDO, o (None, motivo).

    Se reintenta porque una camara recien abierta tarda en ajustar la
    exposicion; se rinde con un motivo legible en vez de devolver algo inservible.
    """
    import cv2
    cap = cv2.VideoCapture(indice)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    try:
        ultimo = None
        for _ in range(intentos):
            for _ in range(calentar):
                cap.read()
            time.sleep(0.3)
            ok, f = cap.read()
            if not ok:
                continue
            br, sd, vale = calidad(f)
            ultimo = (br, sd)
            if vale:
                return f, None
        if ultimo is None:
            return None, "la camara no devuelve imagen"
        br, sd = ultimo
        if br < BRILLO_MIN:
            return None, "esta demasiado oscuro, no veo nada"
        return None, "la imagen no tiene contraste, no distingo nada"
    finally:
        cap.release()


def pregunta_al_modelo(frame, pregunta, timeout=180):
    import cv2
    b64 = base64.b64encode(cv2.imencode(".jpg", frame)[1]).decode()
    cuerpo = json.dumps({"model": MODELO, "prompt": pregunta, "images": [b64],
                         "stream": False, "think": False}).encode()
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=cuerpo,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()).get("response", "").strip()


def _plantilla(pregunta):
    """Pedir respuestas CORTAS: esto se va a escuchar, no a leer."""
    base = ("Eres los ojos de un robot. Responde en espanol, en UNA o DOS frases "
            "cortas, describiendo solo lo que se ve. Si no distingues algo con "
            "seguridad, dilo en vez de suponerlo.\n\n")
    return base + (pregunta or "Que ves?")


def mira(direccion="frente", pregunta=None, tower_port=None):
    """Mirar en una direccion y describir. Devuelve texto para decir en voz alta.

    Si hay que girar la torre, se vuelve SIEMPRE a la pose de partida -- tambien
    si algo falla por el camino -- porque la calibracion de la camara depende de
    ese angulo.
    """
    if direccion in ("cerca", "cerca_izq", "cerca_der"):
        idx = CAMARAS.get("cerca_der" if direccion == "cerca" else direccion)
        f, motivo = captura(idx)
        if f is None:
            return motivo
        return pregunta_al_modelo(f, _plantilla(pregunta))

    giro = GIRO.get(direccion)
    if giro is None:
        f, motivo = captura(CAMARAS["frente"])
        if f is None:
            return motivo
        return pregunta_al_modelo(f, _plantilla(pregunta))

    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import tower
    port = tower_port or os.environ.get("LEX_XLE_TOWER_PORT",
                                        "/dev/cu.usbmodem5B610332201")
    drv = tower.TowerDriver(port=port)
    try:
        st = drv.read()
        pan0, tilt0 = st["pan_ticks"], st["tilt_ticks"]
        drv.hold()
        drv.move_to(pan_ticks=tower.clamp_ticks(pan0 + giro, tower.DEFAULT_PAN_LIMITS),
                    tilt_ticks=tilt0)
        time.sleep(1.8)
        f, motivo = captura(CAMARAS["frente"])
        texto = motivo if f is None else pregunta_al_modelo(f, _plantilla(pregunta))
    finally:
        try:
            drv.move_to(pan_ticks=pan0, tilt_ticks=tilt0)
            time.sleep(1.8)
            drv.hold()
            vuelta = drv.read()
            if abs(vuelta["pan_ticks"] - pan0) > 20:
                texto = (f"{texto} (aviso: la torre no volvio a su sitio, "
                         "la calibracion de la camara puede haberse invalidado)")
        except Exception:
            pass
        drv.close()
    return texto


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--direccion", default="frente",
                    choices=["frente", "derecha", "izquierda", "mucho_derecha",
                             "mucho_izquierda", "cerca", "cerca_izq", "cerca_der"])
    ap.add_argument("--pregunta", default=None)
    a = ap.parse_args()
    print(mira(a.direccion, a.pregunta))
