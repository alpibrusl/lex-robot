#!/usr/bin/env python3
"""Agrupar varias tandas de muestras y resolver los extrinsecos una sola vez.

Una tanda sola da 7-11 poses utiles, y el ajuste estima 9 incognitas (6 de pose
de camara + 3 del desfase de los dedos). Con tan pocos puntos el error de ajuste
baja a 1.8 px pero el de validacion se queda en 5.4: eso es memorizacion, no
precision. Mismo remedio que con los intrinsecos, donde 117 vistas agrupadas
dieron 0.45 px de rms: juntar tandas.

  python scripts/calibrate_head_camera.py ... --samples-out cal/ext_a.json
  python scripts/calibrate_head_camera.py ... --samples-out cal/ext_b.json
  python scripts/pool_extrinsics.py cal/ext_*.json \
      --intrinsics calibration/head_intrinsics_mac_640x480.pooled.json \
      --out calibration/head_extrinsics_mac.json

Las tandas deben compartir la MISMA pose de torre: si la camara se movio entre
medias, los extrinsecos de una no valen para la otra y agruparlas mezcla dos
calibraciones distintas en una peor que cualquiera de las dos.
"""
import argparse
import json
import os
import pathlib
import sys

import cv2
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from calibrate_head_camera import ARM_JOINTS, solve_with_tool_offset  # noqa: E402


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("samples", nargs="+", help="ficheros de --samples-out")
    p.add_argument("--intrinsics", required=True)
    # El 4.0 original se puso para el Pi. Medido en este brazo: el detector
    # repite a 0.6 px (misma pose en 3 tandas, areas identicas), el residuo NO
    # correlaciona con el giro de muneca (r=-0.04, o sea no es la silueta), y
    # agrupar 3 tandas EMPEORO la validacion (7.9 vs 5.4 px) en vez de mejorarla
    # -- señal de error sistematico, no estadistico. Lo que queda es la
    # cinematica: 5 px a f=349 y 0.3 m son 4.4 mm, la precision tipica de un
    # SO-101 con servos Feetech y calibracion a mano. El liston no puede pedir
    # mas de lo que el brazo sabe de si mismo.
    p.add_argument("--max-reproj-px", type=float, default=4.0,
                   help="listón sobre la validacion; 4.0 asume una cinematica "
                        "mejor de la que tiene este brazo (~8 px = ~7 mm)")
    p.add_argument("--out", default="")
    a = p.parse_args()

    from lerobot.model.kinematics import RobotKinematics

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM_JOINTS,
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link"))

    ins = json.loads(pathlib.Path(a.intrinsics).read_text())
    K = np.array(ins["K"], np.float64)
    dist = np.array(ins["dist"], np.float64).reshape(-1, 1)

    samples, towers = [], set()
    for f in a.samples:
        d = json.loads(pathlib.Path(f).read_text())
        got = d if isinstance(d, list) else d.get("samples", [])
        got = [x for x in got if "joints_deg" in x]
        if isinstance(d, dict) and "tower_reference" in d:
            towers.add(json.dumps(d["tower_reference"], sort_keys=True))
        print(f"  {f}: {len(got)} muestras con angulos")
        samples += got
    if len(towers) > 1:
        print("  AVISO: las tandas no comparten pose de torre; son calibraciones "
              "distintas y agruparlas empeora ambas")
    if len(samples) < 8:
        sys.exit(f"solo {len(samples)} muestras; hacen falta bastantes mas que 9 "
                 "incognitas para que el ajuste signifique algo")

    obj_T = np.array([np.asarray(kin.forward_kinematics(
        np.array([x["joints_deg"][j] for j in ARM_JOINTS], np.float64)), np.float64)
        for x in samples])
    img = np.array([x["pixel"] for x in samples], np.float64)
    obj = obj_T[:, :3, 3]
    print(f"\n  {len(samples)} muestras; recorrido "
          f"x {np.ptp(obj[:, 0])*100:.0f} y {np.ptp(obj[:, 1])*100:.0f} "
          f"z {np.ptp(obj[:, 2])*100:.0f} cm")

    ok, r0, t0 = cv2.solvePnP(obj, img, K, dist, flags=cv2.SOLVEPNP_SQPNP)
    if not ok:
        sys.exit("el PnP de arranque no converge")
    x, keep, e, loo = solve_with_tool_offset(obj_T, img, K, dist, r0, t0)
    tool = x[6:9]
    print(f"  ajuste: {keep.sum()}/{len(samples)} poses, media {e[keep].mean():.2f} px")
    print(f"  desfase de la pinza ({tool[0]*100:+.1f},{tool[1]*100:+.1f},"
          f"{tool[2]*100:+.1f}) cm")
    if loo is None or not len(loo):
        sys.exit("sin validacion dejando uno fuera; no escribo nada")
    print(f"  dejando uno fuera: media {loo.mean():.2f} px  max {loo.max():.2f} px")

    R, _ = cv2.Rodrigues(x[:3])
    C = (-R.T @ x[3:6].reshape(3, 1)).ravel()
    print(f"  camara en marco del brazo ({C[0]:+.3f},{C[1]:+.3f},{C[2]:+.3f}) m")
    print(f"  det(R) {np.linalg.det(R):+.3f}")

    # Se juzga por el error sobre puntos NO vistos, no por el de ajuste.
    if loo.mean() > a.max_reproj_px:
        print(f"\n  NO ESCRIBO: {loo.mean():.2f} px en validacion supera "
              f"{a.max_reproj_px}. Mas tandas es la cura; un ajuste flojo da "
              "posiciones equivocadas con toda confianza.")
        return 1
    if not a.out:
        return 0
    out = {"pos": [round(float(v), 5) for v in C],
           "right": [round(float(v), 6) for v in R[0]],
           "down": [round(float(v), 6) for v in R[1]],
           "forward": [round(float(v), 6) for v in R[2]],
           "fx": round(float(K[0, 0]) / 640, 6), "fy": round(float(K[1, 1]) / 480, 6),
           "cx0": round(float(K[0, 2]) / 640, 6), "cy0": round(float(K[1, 2]) / 480, 6),
           **dict(zip(("k1", "k2", "p1", "p2", "k3"),
                      [round(float(v), 8) for v in dist.ravel()[:5]])),
           "gripper_tool_offset_m": [round(float(v), 5) for v in tool],
           "_provenance": {
               "method": f"eye-to-hand PnP agrupado sobre {len(a.samples)} tandas, "
                         "estimando tambien el desfase de los dedos respecto a "
                         "gripper_frame_link",
               "pooled_from": list(a.samples),
               "poses_used": int(keep.sum()), "poses_total": len(samples),
               "reprojection_px": {"fit_mean": round(float(e[keep].mean()), 2),
                                   "leave_one_out_mean": round(float(loo.mean()), 2),
                                   "leave_one_out_max": round(float(loo.max()), 2)}}}
    pathlib.Path(a.out).write_text(json.dumps(out, indent=2) + "\n")
    print(f"\n  -> escrito {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
