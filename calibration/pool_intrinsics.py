"""Ajuste conjunto de las tres tandas. El JSON guarda las esquinas detectadas
justo para esto: 66 vistas juntas sujetan la distorsion mucho mejor que 22."""
import json, math, sys, numpy as np, cv2
FILES = [f"calibration/head_intrinsics_mac_640x480{s}.json" for s in ("", ".run2", ".run3")]
runs = [json.load(open(f)) for f in FILES]
W, H = runs[0]["width"], runs[0]["height"]
COLS, ROWS = 9, 6
sq = runs[0]["square_mm"]
assert all(r["width"]==W and r["height"]==H for r in runs), "resoluciones distintas: no se pueden fundir"
objp = np.array([[c*sq/1000, r*sq/1000, 0] for r in range(ROWS) for c in range(COLS)], np.float32)

corners, meta = [], []
for r in runs:
    for m in r["diversity"]:
        corners.append(np.array(m["corners"], np.float32).reshape(-1,1,2)); meta.append(m)
print(f"{len(corners)} vistas de {len(runs)} tandas, {W}x{H}")

def fit(idx):
    rms,K,dist,rv,tv = cv2.calibrateCamera([objp]*len(idx),[corners[i] for i in idx],(W,H),None,None)
    per=[]
    for j,i in enumerate(idx):
        pr,_ = cv2.projectPoints(objp, rv[j], tv[j], K, dist)
        per.append((i, float(np.sqrt(np.mean(np.sum((pr.reshape(-1,2)-corners[i].reshape(-1,2))**2,axis=1))))))
    return rms,K,dist,per

idx = list(range(len(corners)))
rms,K,dist,per = fit(idx)
dropped = [(i,e) for i,e in per if e > 1.5]
if dropped:
    print(f"descarto {len(dropped)} vistas movidas (>1.5 px)")
    idx = [i for i,e in per if e <= 1.5]; rms,K,dist,per = fit(idx)
fx,fy,cx,cy = K[0][0],K[1][1],K[0][2],K[1][2]
hf = 2*math.degrees(math.atan(W/(2*fx))); k = dist.ravel()
kept=[meta[i] for i in idx]; near=sum(1 for m in kept if m["edge_gap"]<60)
ar=[m["area"] for m in kept]
print(f"\nCONJUNTO ({len(kept)} vistas)  RMS {rms:.3f} px")
print(f"  vistas al borde {near}/{len(kept)}   area {100*min(ar):.1f}-{100*max(ar):.1f}%")
print(f"  fx={fx:.1f} fy={fy:.1f} (fx/fy={fx/fy:.5f})   FOV {hf:.1f} deg")
print(f"  cx={cx:.1f} ({100*(cx-W/2)/W:+.1f}%)  cy={cy:.1f} ({100*(cy-H/2)/H:+.1f}%)")
print(f"  k1={k[0]:+.4f} k2={k[1]:+.4f} p1={k[2]:+.5f} p2={k[3]:+.5f} k3={k[4]:+.4f}")
print(f"  normalizado: fx={fx/W:.5f} fy={fy/H:.5f} cx0={cx/W:.5f} cy0={cy/H:.5f}")
ind=[r["normalized"]["fx"] for r in runs]
print(f"\n  fx individuales: {', '.join(f'{v:.5f}' for v in ind)}  (dispersion {100*(max(ind)-min(ind))/np.mean(ind):.1f}%)")
print(f"  fx conjunta    : {fx/W:.5f}   desvia {100*(fx/W-np.mean(ind))/np.mean(ind):+.1f}% de la media")

bad=[]
if not 40<hf<110: bad.append(f"FOV {hf:.0f} imposible")
if abs(k[0])>0.8: bad.append(f"k1={k[0]:+.2f} enorme")
if abs(k[4])>5: bad.append(f"k3={k[4]:+.1f} enorme")
if abs(cx-W/2)/W>0.08 or abs(cy-H/2)/H>0.08: bad.append("punto principal descentrado")
if rms>1.0: bad.append(f"RMS {rms:.2f} > 1.0")
if bad:
    print("\n*** RECHAZADA ***"); [print("   ",b) for b in bad]; sys.exit(2)
json.dump({"rms_px":float(rms),"width":W,"height":H,"K":K.tolist(),"dist":k.tolist(),
           "views":len(kept),"board":f"{COLS}x{ROWS}","square_mm":sq,
           "camera":f"index 0 (darwin)","pooled_from":FILES,"diversity":kept,
           "normalized":{"fx":fx/W,"fy":fy/H,"cx0":cx/W,"cy0":cy/H}},
          open("calibration/head_intrinsics_mac_640x480.pooled.json","w"), indent=2)
print("\nACEPTADA -> calibration/head_intrinsics_mac_640x480.pooled.json")
