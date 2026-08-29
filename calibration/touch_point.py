"""Lee la FK de la pinza y la asocia a un punto conocido del tablero.

Mitad "brazo" de la extrinseca por cinematica: en vez de medir con cinta donde
esta el tablero respecto al brazo -- cuyo origen esta DENTRO del robot -- se
lleva la pinza a tocar esquinas del tablero y se lee la cinematica directa.

NO USA SO101Follower a proposito. Su connect() llama a configure(), que usa un
`torque_disabled()` que VUELVE A ACTIVAR el par al salir. Con el operador
sujetando el brazo sobre un punto y una Goal_Position antigua en el servo, eso
puede dar un tiron. Aqui se abre el bus en crudo con la calibracion cargada a
mano: solo lecturas, ni un registro escrito, y el cierre pasa
disable_torque=False para que tampoco escriba al salir.

Tres lecturas por punto: si el brazo tiembla o se apoya mal, la dispersion lo
delata en vez de colarse en el ajuste.
"""
import argparse, json, os, statistics as st
from pathlib import Path
from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus
from lerobot.model.kinematics import RobotKinematics
from lerobot.robots.so_follower.robot_kinematic_processor import (
    compute_forward_kinematics_joints_to_ee)

ARM = ["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]
PORTS = {"left":  "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00",
         "right": "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B61033220-if00"}
CAL = Path.home()/".cache/huggingface/lerobot/calibration/robots/so_follower"

ap = argparse.ArgumentParser()
ap.add_argument("--name", required=True)
ap.add_argument("--board-mm", nargs=2, type=float, required=True, metavar=("X","Y"))
ap.add_argument("--arm", default="left", choices=["left","right"])
ap.add_argument("--out", required=True)
a = ap.parse_args()

raw = json.loads((CAL/f"xle_{a.arm}.json").read_text())
calib = {n: MotorCalibration(**v) for n, v in raw.items()}
motors = {n: Motor(v["id"], "sts3215", MotorNormMode.DEGREES) for n, v in raw.items()}

bus = FeetechMotorsBus(port=PORTS[a.arm], motors=motors, calibration=calib)
bus.connect(handshake=False)          # sin configure(), sin tocar el par
try:
    on = [j for j in ARM if int(bus.read("Torque_Enable", j, normalize=False))]
    if on:
        print(f"AVISO: el par esta ACTIVO en {on} — el brazo no se movera a mano")
    # La pinza cerrada da un punto definido; abierta, gripper_frame_link queda
    # en el aire entre los dedos. En ESTA unidad la calibracion esta invertida
    # (ver LEX_XLE_GRIPPER_CLOSED_PCT=0 en deploy/pi/), asi que "cerrada" no es
    # 0 grados: se compara contra el range_min en TICKS, que no depende de eso.
    gt = int(bus.read("Present_Position", "gripper", normalize=False))
    gmin = raw["gripper"]["range_min"]
    if gt - gmin > 120:
        print(f"AVISO: pinza abierta ({gt} ticks, minimo {gmin}) — cierrala")
    kin = RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME","gripper_frame_link"),
                          joint_names=ARM)
    ees, joints = [], None
    for _ in range(3):
        pos = bus.sync_read("Present_Position")           # normalizado a grados
        j = {f"{k}.pos": float(v) for k, v in pos.items()}
        joints = joints or j
        e = compute_forward_kinematics_joints_to_ee(dict(j), kin, ARM)
        ees.append([float(e["ee.x"]),float(e["ee.y"]),float(e["ee.z"])])
    ee = [st.median([e[i] for e in ees]) for i in range(3)]
    spread = max(max(e[i] for e in ees)-min(e[i] for e in ees) for i in range(3))*1000
    print(f"punto {a.name} -> brazo {a.arm}: "
          f"x={ee[0]*1000:7.1f} y={ee[1]*1000:7.1f} z={ee[2]*1000:7.1f} mm")
    print(f"   dispersion {spread:.2f} mm "
          f"{'(estable)' if spread < 1.5 else '(SE MUEVE, sujeta mejor y repite)'}")
    f = Path(a.out)
    data = json.loads(f.read_text()) if f.exists() else {}
    data[a.name] = {"arm_m": ee, "board_mm": [a.board_mm[0], a.board_mm[1], 0.0],
                    "spread_mm": spread, "joints": joints}
    f.write_text(json.dumps(data, indent=2))
    print(f"   guardados {len(data)} puntos")
finally:
    bus.disconnect(disable_torque=False)
