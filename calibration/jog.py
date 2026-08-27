"""Mover articulaciones del brazo en pasos pequenos, con par limitado.

Control ARTICULAR, no cartesiano: la IK oscila cerca del limite de alcance
(medido: 97 mm de error en +x desde 468 mm), asi que aqui no se usa. Cada
articulacion se comanda directamente y se interpola en pasos de STEP grados.

Nunca escribe Torque_Enable=0 al salir: si el brazo esta sujetando algo o
levantado, soltar el par lo deja caer. El par se deja como estaba salvo que se
pida --release.
"""
import argparse, json, time
from pathlib import Path
from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

ARM=["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]
PORTS={"left":"5B3D043715","right":"5B61033220"}
STEP=2.0

ap=argparse.ArgumentParser()
ap.add_argument("--arm",default="right",choices=list(PORTS))
ap.add_argument("--set",nargs=2,action="append",metavar=("JOINT","DEG"),
                help="articulacion y angulo ABSOLUTO en grados")
ap.add_argument("--delta",nargs=2,action="append",metavar=("JOINT","DEG"),
                help="incremento en grados sobre la posicion actual")
ap.add_argument("--torque",type=int,default=350)
ap.add_argument("--settle",type=float,default=0.06)
ap.add_argument("--release",action="store_true",help="soltar el par al terminar")
a=ap.parse_args()

raw=json.loads((Path.home()/f".cache/huggingface/lerobot/calibration/robots/so_follower/xle_{a.arm}.json").read_text())
bus=FeetechMotorsBus(port=f"/dev/serial/by-id/usb-1a86_USB_Single_Serial_{PORTS[a.arm]}-if00",
    motors={n:Motor(v["id"],"sts3215",MotorNormMode.DEGREES) for n,v in raw.items()},
    calibration={n:MotorCalibration(**v) for n,v in raw.items()})
bus.connect(handshake=False)
try:
    cur=dict(bus.sync_read("Present_Position"))
    tgt=dict(cur)
    for j,v in (a.set or []):   tgt[j]=float(v)
    for j,v in (a.delta or []): tgt[j]=cur[j]+float(v)
    moving={j:(cur[j],tgt[j]) for j in ARM if abs(tgt[j]-cur[j])>0.05}
    if not moving:
        # --release por si solo es un uso legitimo: soltar el par sin mover nada.
        # Salir aqui dejaba los servos forzando indefinidamente.
        if a.release:
            for j in ARM:
                bus.write("Torque_Enable", j, 0)
            print("par soltado en las 6, sin mover nada")
        else:
            print("nada que mover")
        raise SystemExit(0)
    for j,(c,t) in moving.items(): print(f"  {j}: {c:.1f} -> {t:.1f} ({t-c:+.1f} deg)")
    for j in ARM:
        bus.write("Torque_Limit",j,a.torque,normalize=False)
    bus.sync_write("Goal_Position",cur)          # objetivo = donde esta, sin tiron
    for j in ARM:
        bus.write("Torque_Enable",j,1,normalize=False)
    time.sleep(0.25)
    n=max(1,int(max(abs(t-c) for c,t in moving.values())/STEP))
    for k in range(1,n+1):
        bus.sync_write("Goal_Position",
            {j:(cur[j]+(tgt[j]-cur[j])*k/n) for j in ARM})
        time.sleep(a.settle)
    time.sleep(0.4)
    got=bus.sync_read("Present_Position")
    for j in moving:
        print(f"  {j}: llego a {got[j]:.1f} (pedido {tgt[j]:.1f}, error {got[j]-tgt[j]:+.1f})")
    if a.release:
        for j in ARM: bus.write("Torque_Enable",j,0,normalize=False)
        print("  par soltado")
    else:
        print("  par MANTENIDO (usa --release para soltarlo)")
finally:
    bus.disconnect(disable_torque=False)
