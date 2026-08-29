"""Ajuste conjunto de la transformacion tablero->brazo y el desfase de la punta.

La FK devuelve la pose de gripper_frame_link, no de la punta que toca el papel.
La punta esta en un punto FIJO pero desconocido del marco de la muneca, asi que
para cada toque i:

    T_i @ [off,1]  ==  R * p_i + t          (p_i = coordenada en el tablero)

Esto invalida la comprobacion ingenua "la distancia entre dos toques debe ser
la del tablero": solo se cumple si la muneca no gira entre ambos. Cuando gira,
gripper_frame se desplaza aunque la punta este quieta -- medido: el MISMO punto
leido dos veces con distinta orientacion dio 28.3 mm de diferencia.

Se resuelve alternando dos pasos, ambos cerrados (sin scipy):
  1. con el desfase fijo -> Kabsch da (R, t) optimos
  2. con (R, t) fijos    -> el desfase sale de un sistema lineal
Converge en pocas iteraciones.
"""
import argparse, json, os
import numpy as np
from lerobot.model.kinematics import RobotKinematics

ARM = ["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]

def kabsch(A, B):
    """R,t que llevan A sobre B minimizando el error cuadratico."""
    ca, cb = A.mean(0), B.mean(0)
    H = (A - ca).T @ (B - cb)
    U, S, Vt = np.linalg.svd(H)
    D = np.diag([1, 1, np.sign(np.linalg.det(Vt.T @ U.T))])
    R = Vt.T @ D @ U.T
    return R, cb - R @ ca

def fit(T, P, iters=200):
    off = np.zeros(3)
    R = np.eye(3); t = P.mean(0)
    for _ in range(iters):
        tips = np.array([(Ti @ np.append(off, 1.0))[:3] for Ti in T])
        R, t = kabsch(P, tips)                      # paso 1
        # paso 2: R_i @ off = R@p_i + t - p_i_fk
        A = np.vstack([Ti[:3, :3] for Ti in T])
        b = np.concatenate([R @ p + t - Ti[:3, 3] for Ti, p in zip(T, P)])
        new, *_ = np.linalg.lstsq(A, b, rcond=None)
        if np.linalg.norm(new - off) < 1e-9:
            off = new; break
        off = new
    tips = np.array([(Ti @ np.append(off, 1.0))[:3] for Ti in T])
    R, t = kabsch(P, tips)
    res = np.linalg.norm(tips - (P @ R.T + t), axis=1)
    return R, t, off, res

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    kin = RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link"),
                          joint_names=ARM)
    d = json.load(open(a.points)); names = sorted(d)
    T = [np.asarray(kin.forward_kinematics(
            np.array([d[n]["joints"][f"{j}.pos"] for j in ARM]))).reshape(4, 4)
         for n in names]
    P = np.array([np.array(d[n]["board_mm"]) / 1000.0 for n in names])
    R, t, off, res = fit(T, P)
    print(f"{len(names)} toques: {', '.join(names)}")
    print(f"\nresiduo: medio {res.mean()*1000:.2f} mm, maximo {res.max()*1000:.2f} mm")
    for n, e in zip(names, res):
        flag = "   <- sospechoso" if e * 1000 > 3 * res.mean() * 1000 else ""
        print(f"   {n}: {e*1000:6.2f} mm{flag}")
    print(f"\ndesfase de la punta respecto a gripper_frame_link:")
    print(f"   ({off[0]*1000:+.1f}, {off[1]*1000:+.1f}, {off[2]*1000:+.1f}) mm"
          f"   |modulo| {np.linalg.norm(off)*1000:.1f} mm")
    if a.out:
        json.dump({"R_board_to_arm": R.tolist(), "t_board_to_arm": t.tolist(),
                   "tool_offset_m": off.tolist(),
                   "residual_mm": {n: float(e*1000) for n, e in zip(names, res)},
                   "points_used": names}, open(a.out, "w"), indent=2)
        print(f"\nescrito {a.out}")
