"""Auditar un conjunto de demostraciones antes de entrenar.

Por que molestarse: ACT no distingue una toma buena de una mala. Trata TODO
lo que le des como ejemplo experto a imitar, asi que un episodio en el que se
te escapo la estrella no lo ignora -- aprende a que se le escape. Quitar las
fallidas es la primera palanca de calidad, por delante de grabar mas.

Dos capas, de barata a cara:

1. Comprobaciones mecanicas, sobre los numeros que ya estan en el conjunto.
   Son las que recomiendan las guias de lerobot: duracion de los episodios
   parecida, sin fotogramas perdidos, articulaciones dentro de rango, y que
   el brazo de verdad siguiera a las ordenes.

2. El modelo local mirando el ultimo fotograma (--mirar). Detectar exito con
   un modelo de vision es un patron conocido, planteado como pregunta sobre
   la imagen en vez de como deteccion: nuestro qwen describe bien pero no
   localiza, asi que se le pregunta por el ESTADO ("¿sujeta la pinza la
   estrella?"), nunca por coordenadas.

Uso:
    python scripts/auditar_demos.py [conjunto] [--mirar]
"""

import glob
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent / "sidecar"))

EJES = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

# Umbrales. Los tres primeros salen de las guias de lerobot; los otros de lo
# que significa fisicamente una toma inutil.
RATIO_DURACION = 2.0    # el episodio mas largo no debe doblar al mas corto
MARGEN_LIMITE = 1.0     # unidades normalizadas de holgura contra el tope
MOVIMIENTO_MIN = 40.0   # por debajo de esto el brazo practicamente no se movio
PINZA_MIN = 5.0         # recorrido de pinza: sin esto no hubo intento de agarre
DESVIO_MAX = 0.45       # cuanto puede quedarse el brazo detras de lo ordenado


def cargar(raiz: Path):
    datos = pd.concat(
        [pd.read_parquet(f) for f in sorted(glob.glob(str(raiz / "data" / "**" / "*.parquet"), recursive=True))]
    )
    metas = pd.concat(
        [pd.read_parquet(f) for f in sorted(glob.glob(str(raiz / "meta" / "episodes" / "**" / "*.parquet"), recursive=True))]
    )
    info = json.load(open(raiz / "meta" / "info.json"))
    return datos, metas, info


def ultimo_fotograma(raiz: Path, meta_ep, camara: str):
    """Sacar el fotograma final del episodio. Un mp4 por camara, con marcas."""
    import cv2

    ruta = raiz / "videos" / f"observation.images.{camara}" / f"chunk-{int(meta_ep[f'videos/observation.images.{camara}/chunk_index']):03d}" / f"file-{int(meta_ep[f'videos/observation.images.{camara}/file_index']):03d}.mp4"
    if not ruta.is_file():
        return None
    fin = float(meta_ep[f"videos/observation.images.{camara}/to_timestamp"])
    cap = cv2.VideoCapture(str(ruta))
    try:
        # Medio segundo antes del final: el ultimo fotograma exacto a veces
        # no se puede decodificar tras el salto.
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, fin - 0.5) * 1000)
        ok, frame = cap.read()
        return frame if ok else None
    finally:
        cap.release()


def juzgar_con_modelo(raiz: Path, meta_ep, tarea: str):
    """Preguntar al modelo local si el episodio acabo bien."""
    import vision

    frame = ultimo_fotograma(raiz, meta_ep, "wrist")
    if frame is None:
        return None, "sin video de muñeca"

    # No preguntar sobre un fotograma que no se ve. El modelo NO dice "no veo
    # nada": describio en su dia una imagen completamente negra con todo
    # detalle. Un veredicto inventado es peor que no tener veredicto.
    brillo, contraste, sirve = vision.calidad(frame)
    if not sirve:
        return None, f"fotograma inservible (brillo {brillo:.0f}, contraste {contraste:.0f})"

    pregunta = (
        f"Esta es la vista desde la pinza de un brazo robotico al final de un intento "
        f"de: {tarea}. Responde SOLO con una palabra: SI si la pinza esta sujetando el "
        f"objeto, NO si no lo sujeta o no se aprecia."
    )
    try:
        r = vision.pregunta_al_modelo(frame, pregunta, timeout=120).strip().upper()
    except Exception as e:
        return None, f"el modelo no contesto ({type(e).__name__})"
    if r.startswith("SI") or r.startswith("SÍ"):
        return True, r[:40]
    if r.startswith("NO"):
        return False, r[:40]
    return None, f"respuesta ambigua: {r[:40]}"


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    mirar = "--mirar" in sys.argv
    nombre = args[0] if args else "xle_estrella"
    raiz = Path(os.path.expanduser(f"~/lex-robot-datasets/{nombre}"))
    if not raiz.is_dir():
        print(f"No encuentro {raiz}", file=sys.stderr)
        return 1

    datos, metas, info = cargar(raiz)
    fps = info.get("fps", 30)
    print(f"{nombre}: {len(metas)} episodios, {len(datos)} fotogramas, {fps} fps\n")

    duraciones = metas["length"].to_numpy()
    problemas = {}

    def anotar(ep, texto):
        problemas.setdefault(int(ep), []).append(texto)

    # Duracion dispar: si un episodio dobla a otro, o sobra cola o falto tarea.
    if len(duraciones) > 1 and duraciones.max() > RATIO_DURACION * duraciones.min():
        for _, m in metas.iterrows():
            if m["length"] > RATIO_DURACION * duraciones.min():
                anotar(m["episode_index"], f"dura {m['length']} frente a {duraciones.min()} del mas corto")

    for ep, g in datos.groupby("episode_index"):
        a = np.stack(g["action"].values)
        s = np.stack(g["observation.state"].values)

        movido = float(np.abs(np.diff(s, axis=0)).sum())
        if movido < MOVIMIENTO_MIN:
            anotar(ep, f"casi no se movio (recorrido total {movido:.0f})")

        pinza = float(s[:, 5].max() - s[:, 5].min())
        if pinza < PINZA_MIN:
            anotar(ep, f"la pinza no se uso (recorrido {pinza:.1f})")

        # ¿El brazo siguio a las ordenes? Si no, lo grabado no es lo que paso.
        desvio = float(np.abs(a - s).mean())
        if desvio > DESVIO_MAX * 10:
            anotar(ep, f"el brazo no siguio las ordenes (desvio medio {desvio:.1f})")

        # Topes: la pinza va de 0 a 100, el resto de -100 a 100.
        for i, eje in enumerate(EJES):
            bajo, alto = (0.0, 100.0) if eje == "gripper" else (-100.0, 100.0)
            if s[:, i].min() < bajo + MARGEN_LIMITE or s[:, i].max() > alto - MARGEN_LIMITE:
                anotar(ep, f"{eje} toco su tope")

        # Fotogramas perdidos: los saltos de tiempo deben ser 1/fps.
        t = g["timestamp"].to_numpy()
        saltos = np.diff(t)
        perdidos = int((saltos > 1.8 / fps).sum())
        if perdidos:
            anotar(ep, f"{perdidos} saltos de tiempo (fotogramas perdidos)")

    veredictos = {}
    if mirar:
        tarea = str(metas.iloc[0]["tasks"][0]) if len(metas) else "coger el objeto"
        print(f"Preguntando al modelo local por el final de cada episodio ({tarea})...\n")
        for _, m in metas.iterrows():
            ok, detalle = juzgar_con_modelo(raiz, m, tarea)
            veredictos[int(m["episode_index"])] = (ok, detalle)
            if ok is False:
                anotar(m["episode_index"], f"el modelo no ve el objeto sujeto: {detalle}")

    for _, m in metas.iterrows():
        ep = int(m["episode_index"])
        fallos = problemas.get(ep, [])
        marca = "REVISAR" if fallos else "ok     "
        extra = ""
        if ep in veredictos:
            ok, detalle = veredictos[ep]
            extra = {True: "  modelo: sujeta", False: "  modelo: NO sujeta", None: f"  modelo: {detalle}"}[ok]
        print(f"  episodio {ep:3d}  {m['length']:4d} frames  {marca}{extra}")
        for f in fallos:
            print(f"                 - {f}")

    sospechosos = sorted(problemas)
    print(f"\n{len(metas) - len(sospechosos)} de {len(metas)} episodios limpios.")
    if sospechosos:
        print(f"A revisar: {sospechosos}")
        print(
            "\nMiralos antes de entrenar. ACT imita todo lo que le des, asi que una\n"
            "toma fallida no la ignora: aprende a fallar igual."
        )
    if not mirar:
        print("\nCon --mirar, el modelo local juzga ademas si el objeto acabo sujeto.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
