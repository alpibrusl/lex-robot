"""Captura de intrínsecos con rechazo de vistas movidas y comprobaciones físicas.

Lecciones de las tres tandas anteriores, todas incorporadas:
  * 20 vistas idénticas dan RMS 0.127 px y un FOV de 26 grados: el RMS bajo
    mide sobreajuste, no validez. De ahí las comprobaciones físicas al final.
  * Las vistas casi duplicadas no aportan nada, así que se descartan al vuelo.
  * Cinco vistas movidas subieron el RMS de 0.56 a 2.52 px. Ahora se ajusta,
    se mide el error POR VISTA, se tiran las malas y se reajusta.
  * Las esquinas del encuadre son las que sujetan la distorsión, así que se
    informa de cuántas vistas llegaron al borde.
  * Se guardan las esquinas detectadas: sin ellas no se puede reajustar ni
    ampliar, que es exactamente lo que nos pasó al perder /tmp.

Escribe en calibration/, NO en /tmp: /tmp se borra al reiniciar.
"""
import argparse, json, math, sys, time
import cv2, numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--views", type=int, default=22)
ap.add_argument("--settle", type=float, default=3.5)
ap.add_argument("--square-mm", type=float, default=20.15)
ap.add_argument("--camera", type=int, default=0)
ap.add_argument("--width", type=int, default=1280)
ap.add_argument("--height", type=int, default=960)
ap.add_argument("--max-view-err", type=float, default=1.5)
ap.add_argument("--out", required=True)
a = ap.parse_args()

COLS, ROWS, W, H = 9, 6, a.width, a.height
FLAGS = cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE
objp = np.array([[c*a.square_mm/1000, r*a.square_mm/1000, 0]
                 for r in range(ROWS) for c in range(COLS)], np.float32)

cap = cv2.VideoCapture(a.camera, cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
cap.set(cv2.CAP_PROP_FRAME_WIDTH, W); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
time.sleep(1.5)

corners, meta, last = [], [], None
print(f"{a.views} vistas, {a.settle}s entre cada una — MUEVE entre capturas", flush=True)
deadline = time.monotonic() + a.views*a.settle + 240
while len(corners) < a.views and time.monotonic() < deadline:
    ok, frame = cap.read()
    if not ok: continue
    g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    found, cor = cv2.findChessboardCorners(g, (COLS, ROWS), FLAGS)
    if not found: continue
    cv2.cornerSubPix(g, cor, (11,11), (-1,-1),
        (cv2.TERM_CRITERIA_EPS+cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001))
    p = cor.reshape(-1,2); cen = p.mean(0)
    q = cor.reshape(ROWS, COLS, 2)
    dxp = np.linalg.norm(q[:,1:]-q[:,:-1], axis=2)
    slant = float(dxp.std()/dxp.mean())
    area = float((p[:,0].max()-p[:,0].min())*(p[:,1].max()-p[:,1].min())/(W*H))
    if last is not None and np.linalg.norm(cen-last) < 60 and abs(area-meta[-1]["area"]) < 0.02:
        continue
    edge = float(min(p[:,0].min(), W-p[:,0].max(), p[:,1].min(), H-p[:,1].max()))
    corners.append(cor); last = cen
    meta.append({"cx":float(cen[0]),"cy":float(cen[1]),"area":area,
                 "slant":slant,"edge_gap":edge,"corners":p.tolist()})
    print(f"  {len(corners):>2}/{a.views} centro=({cen[0]:4.0f},{cen[1]:4.0f}) "
          f"area={100*area:4.1f}% inclin={slant:.3f} borde={edge:4.0f}px"
          f"{'  BORDE!' if edge < 60 else ''}", flush=True)
    time.sleep(a.settle)
cap.release()

if len(corners) < 8:
    print(f"solo {len(corners)} vistas, hacen falta 8+", file=sys.stderr); sys.exit(1)

def fit(idx):
    rms,K,dist,rv,tv = cv2.calibrateCamera([objp]*len(idx), [corners[i] for i in idx],
                                           (W,H), None, None)
    per=[]
    for j,i in enumerate(idx):
        pr,_ = cv2.projectPoints(objp, rv[j], tv[j], K, dist)
        per.append((i, float(np.sqrt(np.mean(np.sum(
            (pr.reshape(-1,2)-corners[i].reshape(-1,2))**2, axis=1))))))
    return rms, K, dist, per

idx = list(range(len(corners)))
rms, K, dist, per = fit(idx)
print(f"\ncon las {len(idx)} vistas: RMS {rms:.3f} px")
dropped = [(i,e) for i,e in per if e > a.max_view_err]
if dropped:
    print(f"descarto {len(dropped)} vistas movidas (> {a.max_view_err} px): "
          + ", ".join(f"#{i+1}={e:.2f}" for i,e in sorted(dropped,key=lambda t:-t[1])))
    idx = [i for i,e in per if e <= a.max_view_err]
    if len(idx) < 8:
        print("quedan menos de 8 vistas buenas", file=sys.stderr); sys.exit(1)
    rms, K, dist, per = fit(idx)

fx,fy,cx,cy = K[0][0],K[1][1],K[0][2],K[1][2]
hf = 2*math.degrees(math.atan(W/(2*fx))); k = dist.ravel()
kept = [meta[i] for i in idx]
near = sum(1 for m in kept if m["edge_gap"] < 60)
xs=[m["cx"] for m in kept]; ys=[m["cy"] for m in kept]
print(f"\ndiversidad ({len(kept)} vistas)")
print(f"  x {min(xs):.0f}-{max(xs):.0f} ({100*(max(xs)-min(xs))/W:.0f}% del ancho)"
      f"   y {min(ys):.0f}-{max(ys):.0f} ({100*(max(ys)-min(ys))/H:.0f}% del alto)")
print(f"  area {100*min(m['area'] for m in kept):.1f}%-{100*max(m['area'] for m in kept):.1f}%"
      f"   inclinacion max {max(m['slant'] for m in kept):.3f}")
print(f"  vistas tocando el borde: {near}/{len(kept)}"
      f"{'  (bien)' if near>=5 else '  (POCAS: distorsion poco sujeta)'}")
print(f"\nRMS {rms:.3f} px   fx={fx:.1f} fy={fy:.1f} (fx/fy={fx/fy:.5f})   FOV {hf:.1f} deg")
print(f"  cx={cx:.1f} ({100*(cx-W/2)/W:+.1f}%)  cy={cy:.1f} ({100*(cy-H/2)/H:+.1f}%)")
print(f"  k1={k[0]:+.4f} k2={k[1]:+.4f} p1={k[2]:+.5f} p2={k[3]:+.5f} k3={k[4]:+.4f}")

bad=[]
if not 40<hf<110: bad.append(f"FOV {hf:.0f} deg imposible")
if abs(k[0])>0.8: bad.append(f"k1={k[0]:+.2f} enorme")
if abs(k[4])>5:   bad.append(f"k3={k[4]:+.1f} enorme")
if abs(cx-W/2)/W>0.08 or abs(cy-H/2)/H>0.08: bad.append("punto principal muy descentrado")
if rms>1.0:       bad.append(f"RMS {rms:.2f} px por encima de 1.0")
if bad:
    print("\n*** RECHAZADA (un RMS bajo no basta): ***")
    for b in bad: print(f"      {b}")
    sys.exit(2)
json.dump({"rms_px":float(rms),"width":W,"height":H,"K":K.tolist(),"dist":k.tolist(),
           "views":len(kept),"board":f"{COLS}x{ROWS}","square_mm":a.square_mm,
           "camera":f"/dev/video{a.camera}","diversity":kept,
           "normalized":{"fx":fx/W,"fy":fy/H,"cx0":cx/W,"cy0":cy/H}},
          open(a.out,"w"), indent=2)
print(f"\nACEPTADA -> {a.out}")
print(f"  normalizado: fx={fx/W:.5f} fy={fy/H:.5f} cx0={cx/W:.5f} cy0={cy/H:.5f}")
