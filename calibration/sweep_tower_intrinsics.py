#!/usr/bin/env python3
"""Vistas de calibracion moviendo la CAMARA, con el tablero quieto.

Por que existe: las vistas que sujetan la distorsion son las de los BORDES del
encuadre, y a mano salen pocas y desiguales -- 21 de 88 en las cuatro tandas
del Mac. La torre pan/tilt puede llevar el tablero a cualquier punto del
encuadre de forma sistematica y repetible, sin que nadie sostenga nada.

LO QUE ESTO NO DA, dicho antes de que alguien se fie de mas: girar la torre casi
no cambia la DISTANCIA camara-tablero, y la variacion de distancia es parte de
lo que sujeta la focal. Un barrido NO sustituye a las tandas a mano; suma al
ajuste conjunto justo lo que a esas les falta. Usalo con pool_intrinsics.py.

No adivina la escala: mide primero cuantos pixeles mueve el tablero cada tick
(fase A) y luego apunta a posiciones concretas del encuadre (fase B).

SEGURIDAD: todo pasa por tower.py, que sincroniza objetivo con la posicion
actual ANTES de dar par, y por clamp_ticks contra los limites MEDIDOS. Al
terminar vuelve a la pose inicial y suelta, como estaba.
"""
import argparse, json, math, os, sys, time
import cv2, numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sidecar"))
import tower

ap = argparse.ArgumentParser()
ap.add_argument("--port", default=os.environ.get("LEX_XLE_LEFT_PORT"))
ap.add_argument("--camera", type=int, default=0)
ap.add_argument("--width", type=int, default=640)
ap.add_argument("--height", type=int, default=480)
ap.add_argument("--square-mm", type=float, default=20.15)
ap.add_argument("--settle", type=float, default=1.2, help="espera tras mover, por la vibracion")
ap.add_argument("--margin", type=int, default=70, help="px del borde a los que apuntar")
ap.add_argument("--out", required=True)
a = ap.parse_args()

COLS, ROWS, W, H = 9, 6, a.width, a.height
FLAGS = cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE
objp = np.array([[c*a.square_mm/1000, r*a.square_mm/1000, 0]
                 for r in range(ROWS) for c in range(COLS)], np.float32)

cap = cv2.VideoCapture(a.camera)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, W); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
time.sleep(1.0)
ok, probe = cap.read()
if not ok or probe is None:
    print("la camara no entrega fotogramas (en macOS lanzalo desde Terminal.app)", file=sys.stderr)
    sys.exit(1)
if (probe.shape[1], probe.shape[0]) != (W, H):
    print(f"pedi {W}x{H} y entrega {probe.shape[1]}x{probe.shape[0]}", file=sys.stderr); sys.exit(1)

def look():
    """Devuelve (esquinas, centro, area, edge_gap, slant) o None."""
    for _ in range(4): cap.read()
    ok, fr = cap.read()
    if not ok: return None
    g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
    found, cor = cv2.findChessboardCorners(g, (COLS, ROWS), FLAGS)
    if not found: return None
    cv2.cornerSubPix(g, cor, (11,11), (-1,-1),
        (cv2.TERM_CRITERIA_EPS+cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001))
    p = cor.reshape(-1,2); cen = p.mean(0)
    q = cor.reshape(ROWS, COLS, 2); dxp = np.linalg.norm(q[:,1:]-q[:,:-1], axis=2)
    area = float((p[:,0].max()-p[:,0].min())*(p[:,1].max()-p[:,1].min())/(W*H))
    edge = float(min(p[:,0].min(), W-p[:,0].max(), p[:,1].min(), H-p[:,1].max()))
    return cor, cen, area, edge, float(dxp.std()/dxp.mean())

drv = tower.TowerDriver(port=a.port)
st = drv.read(); pan0, tilt0 = st["pan_ticks"], st["tilt_ticks"]
print(f"torre en pan={pan0} tilt={tilt0}; la devuelvo aqui al terminar")
PAN_LO, PAN_HI = tower.DEFAULT_PAN_LIMITS
TILT_LO, TILT_HI = tower.DEFAULT_TILT_LIMITS
print(f"margen pan -{pan0-PAN_LO}/+{PAN_HI-pan0}   tilt -{tilt0-TILT_LO}/+{TILT_HI-tilt0}")

def goto(pan, tilt):
    pan = tower.clamp_ticks(pan, (PAN_LO, PAN_HI))
    tilt = tower.clamp_ticks(tilt, (TILT_LO, TILT_HI))
    drv.move_to(pan_ticks=pan, tilt_ticks=tilt)
    time.sleep(a.settle)
    return pan, tilt

views, meta = [], []
try:
    drv.hold()
    base = look()
    if base is None:
        print("no veo el tablero desde la pose actual; apunta la torre primero", file=sys.stderr)
        sys.exit(1)
    print(f"tablero visible en ({base[1][0]:.0f},{base[1][1]:.0f}), area {100*base[2]:.1f}%")

    # ---- fase A: cuantos pixeles mueve un tick ----
    probes, D = [], 150
    for dp, dt in ((D,0), (-D,0), (0,D), (0,-D)):
        p, t = goto(pan0+dp, tilt0+dt)
        r = look()
        if r: probes.append((p-pan0, t-tilt0, r[1][0], r[1][1]))
        goto(pan0, tilt0)
    if len(probes) < 2:
        print("las poses de sondeo no ven el tablero; no puedo medir la escala", file=sys.stderr)
        sys.exit(1)
    A = np.array([[p, t, 1] for p, t, _, _ in probes], float)
    bx = np.array([x for _, _, x, _ in probes]); by = np.array([y for _, _, _, y in probes])
    kx, *_ = np.linalg.lstsq(A, bx, rcond=None); ky, *_ = np.linalg.lstsq(A, by, rcond=None)
    print(f"escala medida: pan 1 tick -> ({kx[0]:+.2f},{ky[0]:+.2f}) px   "
          f"tilt 1 tick -> ({kx[1]:+.2f},{ky[1]:+.2f}) px")
    J = np.array([[kx[0], kx[1]], [ky[0], ky[1]]])
    if abs(np.linalg.det(J)) < 1e-6:
        print("el mapa ticks->pixel es degenerado", file=sys.stderr); sys.exit(1)
    Jinv = np.linalg.inv(J)

    # ---- fase B: apuntar a posiciones concretas, bordes incluidos ----
    m = a.margin
    targets = [(x, y) for y in (m, H//2, H-m) for x in (m, W//4, W//2, 3*W//4, W-m)]
    targets += [(m, m), (W-m, m), (m, H-m), (W-m, H-m)]     # esquinas, repetidas a proposito
    print(f"\n{len(targets)} posiciones objetivo")
    for i, (tx, ty) in enumerate(targets, 1):
        d = Jinv @ np.array([tx - kx[2], ty - ky[2]])
        p, t = goto(pan0 + int(round(d[0])), tilt0 + int(round(d[1])))
        r = look()
        if r is None:
            print(f"  {i:>2}/{len(targets)} objetivo ({tx},{ty}): el tablero no entra, salto")
            continue
        cor, cen, area, edge, slant = r
        if any(np.linalg.norm(cen - np.array([m2["cx"], m2["cy"]])) < 25 for m2 in meta):
            print(f"  {i:>2}/{len(targets)} ({cen[0]:.0f},{cen[1]:.0f}) casi-duplicada, salto")
            continue
        views.append(cor)
        meta.append({"cx":float(cen[0]),"cy":float(cen[1]),"area":area,"slant":slant,
                     "edge_gap":edge,"corners":cor.reshape(-1,2).tolist(),
                     "pan_ticks":int(p),"tilt_ticks":int(t)})
        print(f"  {i:>2}/{len(targets)} objetivo ({tx:>3},{ty:>3}) -> real ({cen[0]:4.0f},{cen[1]:4.0f})"
              f"  area={100*area:4.1f}%  borde={edge:4.0f}px{'  BORDE!' if edge < 60 else ''}")
finally:
    try:
        goto(pan0, tilt0); drv.release()
        print(f"\ntorre devuelta a pan={pan0} tilt={tilt0} y soltada")
    finally:
        drv.close(); cap.release()

if not views:
    print("ninguna vista util", file=sys.stderr); sys.exit(1)
near = sum(1 for m2 in meta if m2["edge_gap"] < 60)
ar = [m2["area"] for m2 in meta]
print(f"\n{len(views)} vistas   al borde {near}/{len(views)}   area {100*min(ar):.1f}-{100*max(ar):.1f}%")

rms, K, dist, _, _ = cv2.calibrateCamera([objp]*len(views), views, (W,H), None, None)
fx, fy, cx, cy = K[0][0], K[1][1], K[0][2], K[1][2]
hf = 2*math.degrees(math.atan(W/(2*fx))); k = dist.ravel()
print(f"ajuste PROPIO (solo informativo): RMS {rms:.3f} px  fx={fx:.1f}  FOV {hf:.1f} deg")
print(f"  normalizado fx={fx/W:.5f} fy={fy/H:.5f} cx0={cx/W:.5f} cy0={cy/H:.5f}")
print("  OJO: sin variacion de distancia este ajuste por si solo no es fiable.")
json.dump({"rms_px":float(rms),"width":W,"height":H,"K":K.tolist(),"dist":k.tolist(),
           "views":len(views),"board":f"{COLS}x{ROWS}","square_mm":a.square_mm,
           "camera":f"index {a.camera} ({sys.platform})","method":"tower sweep, board fixed",
           "caveat":"camera rotated, so distance barely varies; pool with handheld runs",
           "diversity":meta,
           "normalized":{"fx":fx/W,"fy":fy/H,"cx0":cx/W,"cy0":cy/H}}, open(a.out,"w"), indent=2)
print(f"\n-> {a.out}   (para pool_intrinsics.py)")
