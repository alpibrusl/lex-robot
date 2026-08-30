#!/usr/bin/env python3
"""Apunta la torre al tablero de calibracion, midiendo en vez de adivinando.

Un tablero VERTICAL visto por una camara que mira hacia abajo sale aplastado:
la relacion alto/ancho cae muy por debajo de la que tendria de frente, y con
ella la cobertura del encuadre -- que es lo que de verdad sujeta la
calibracion. Esto barre el tilt (y luego el pan) buscando la pose que MAS
cobertura da, que es la que mas encara el tablero.

No supone hacia donde mira cada signo de tick: lo mide.

SEGURIDAD: todo pasa por tower.py (sincroniza objetivo antes de dar par) y por
clamp contra los limites medidos. Si no encuentra nada mejor, vuelve a la pose
inicial. Deja la torre SUJETA en la mejor pose -- upstream avisa de que los
angulos del cabezal deben mantenerse consistentes, y ademas va suelta y deriva.
"""
import argparse, json, os, sys, time
import cv2, numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sidecar"))
import tower

ap = argparse.ArgumentParser()
ap.add_argument("--port", default=os.environ.get("LEX_XLE_LEFT_PORT"))
ap.add_argument("--camera", type=int, default=0)
ap.add_argument("--width", type=int, default=640)
ap.add_argument("--height", type=int, default=480)
ap.add_argument("--step", type=int, default=80, help="ticks entre muestras")
ap.add_argument("--settle", type=float, default=1.0)
ap.add_argument("--release", action="store_true", help="soltar al final en vez de sujetar")
a = ap.parse_args()

COLS, ROWS, W, H = 9, 6, a.width, a.height
FLAGS = cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE
cap = cv2.VideoCapture(a.camera)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, W); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
time.sleep(1.0)

def look():
    for _ in range(4): cap.read()
    ok, fr = cap.read()
    if not ok: return None
    g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
    found, cor = cv2.findChessboardCorners(g, (COLS, ROWS), FLAGS)
    if not found: return None
    p = cor.reshape(-1,2)
    hull = cv2.contourArea(cv2.convexHull(p.astype(np.float32)))
    bw, bh = float(np.ptp(p[:,0])), float(np.ptp(p[:,1]))
    q = cor.reshape(ROWS, COLS, 2)
    sp = float(min(np.median(np.linalg.norm(q[:,1:]-q[:,:-1],axis=2)),
                   np.median(np.linalg.norm(q[1:,:]-q[:-1,:],axis=2))))
    return {"cov": hull/(W*H), "bw": bw, "bh": bh, "aspect": bh/bw if bw else 0,
            "cx": float(p[:,0].mean()), "cy": float(p[:,1].mean()), "spacing": sp}

drv = tower.TowerDriver(port=a.port)
st = drv.read(); pan0, tilt0 = st["pan_ticks"], st["tilt_ticks"]
PAN_LO, PAN_HI = tower.DEFAULT_PAN_LIMITS
TILT_LO, TILT_HI = tower.DEFAULT_TILT_LIMITS
print(f"pose inicial pan={pan0} tilt={tilt0}")
print(f"margen pan -{pan0-PAN_LO}/+{PAN_HI-pan0}   tilt -{tilt0-TILT_LO}/+{TILT_HI-tilt0}")

def goto(p, t):
    drv.move_to(pan_ticks=tower.clamp_ticks(p,(PAN_LO,PAN_HI)),
                tilt_ticks=tower.clamp_ticks(t,(TILT_LO,TILT_HI)))
    time.sleep(a.settle)

best = None
try:
    drv.hold()
    print("\n-- barrido de TILT (relacion alto/ancho de frente seria ~0.625) --")
    # TODO el recorrido, no solo hacia arriba desde donde este: si la pose de
    # partida ya dejaba el tablero fuera del encuadre (cortado por un borde,
    # que es como NO se detecta), buscar en una sola direccion no lo encuentra.
    tilts = sorted(range(TILT_LO, TILT_HI+1, a.step), key=lambda t: abs(t-tilt0))
    for t in tilts:
        goto(pan0, t); r = look()
        if r is None:
            print(f"  tilt {t:5d}: sin tablero"); continue
        print(f"  tilt {t:5d}: cobertura {100*r['cov']:5.1f}%  {r['bw']:4.0f}x{r['bh']:4.0f} px "
              f" alto/ancho {r['aspect']:.2f}  esquinas {r['spacing']:4.1f} px  centro y={r['cy']:.0f}")
        if best is None or r["cov"] > best[0]["cov"]: best = (r, pan0, t)
    if best is None:
        # Respaldo: rejilla 2D. Barrer solo el tilt falla en cuanto el tablero
        # se sale por un LADO -- entonces no se detecta a ninguna altura, y sin
        # deteccion no hay nada con que decidir hacia donde mirar. Paso tal cual
        # cuando el tablero se acerco y quedo cortado por el borde izquierdo.
        print("\n-- no aparecio barriendo el tilt; rejilla 2D pan x tilt --")
        for p_ in sorted(range(PAN_LO, PAN_HI+1, 3*a.step), key=lambda v: abs(v-pan0)):
            for t_ in sorted(range(TILT_LO, TILT_HI+1, 2*a.step), key=lambda v: abs(v-tilt0)):
                goto(p_, t_); r = look()
                if r is None: continue
                print(f"  encontrado en pan={p_} tilt={t_}: cobertura {100*r['cov']:.1f}% "
                      f"centro ({r['cx']:.0f},{r['cy']:.0f})")
                if best is None or r["cov"] > best[0]["cov"]: best = (r, p_, t_)
            if best is not None: break
    if best is None:
        print("no vi el tablero en ninguna pose", file=sys.stderr); goto(pan0, tilt0); sys.exit(1)

    _, _, tbest = best
    print(f"\n-- barrido de PAN alrededor de pan={best[1]} tilt={tbest} --")
    pbase = best[1]
    for p in range(pbase-4*a.step, pbase+4*a.step+1, a.step):
        goto(p, tbest); r = look()
        if r is None:
            print(f"  pan {p:5d}: sin tablero"); continue
        print(f"  pan {p:5d}: cobertura {100*r['cov']:5.1f}%  centro x={r['cx']:.0f}")
        if r["cov"] > best[0]["cov"]: best = (r, p, tbest)

    r, pb, tb = best
    goto(pb, tb)
    print(f"\nMEJOR: pan={pb} tilt={tb}  cobertura {100*r['cov']:.1f}%  "
          f"{r['bw']:.0f}x{r['bh']:.0f} px  alto/ancho {r['aspect']:.2f}  esquinas {r['spacing']:.1f} px")
    print(f"  (pose inicial daba 10.6% con alto/ancho 0.42)")
    if a.release:
        drv.release(); print("  torre SOLTADA")
    else:
        drv.hold(); print("  torre SUJETA aqui — no la muevas hasta terminar la calibracion")
finally:
    drv.close(); cap.release()
