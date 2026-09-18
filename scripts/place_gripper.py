"""Colocar la pinza resolviendo altura y radio A LA VEZ, no alternando.

La version anterior corregia primero una y luego la otra, y como los ejes estan
ACOPLADOS (subir con el hombro estira el brazo, recoger con el codo lo baja),
cada correccion deshacia la anterior: de radio 34 se fue a 36 buscando 28,
oscilando sin converger.

Aqui se mide el jacobiano 2x2 -- cuanto cambian altura y radio por tick de cada
articulacion -- y se resuelve el paso que corrige las dos cosas de una vez. Se
avanza en pasos acotados y se remide, porque el jacobiano cambia con la postura.
"""
import os, sys, time, json, numpy as np
from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.model.kinematics import RobotKinematics
ARM=["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]
J2=("shoulder_lift","elbow_flex")
H_OBJ=float(os.environ.get("H_OBJ","0.105"))
R_OBJ=float(os.environ.get("R_OBJ","0.28"))
PASO_MAX=90          # ticks por iteracion y articulacion
tc=json.load(open("calibration/table_plane_touch.json"))
n=np.array(tc["normal"],float); c=np.array(tc["centroid"],float)
kin=RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],joint_names=ARM,
                    target_frame_name="gripper_frame_link")
rob=SO101Follower(SO101FollowerConfig(port="/dev/cu.usbmodem5B610332201",id="xle_right"))
rob.bus.connect()
def estado():
    deg=rob.bus.sync_read("Present_Position",num_retry=3)
    P=np.asarray(kin.forward_kinematics(np.array([float(deg[j]) for j in ARM])),float)[:3,3]
    return np.array([float((P-c)@n), float(np.linalg.norm(P[:2]))])
try:
    for j in ARM: rob.bus.write("Torque_Enable",j,1,normalize=False)
    cur={j:int(rob.bus.read("Present_Position",j,normalize=False)) for j in ARM}
    for j in ARM: rob.bus.write("Goal_Position",j,cur[j],normalize=False)
    time.sleep(0.8)
    lim={j:(int(rob.bus.read("Min_Position_Limit",j,normalize=False)),
            int(rob.bus.read("Max_Position_Limit",j,normalize=False))) for j in J2}
    obj=np.array([H_OBJ,R_OBJ])
    for it in range(12):
        x=estado()
        err=obj-x
        print(f"  {it}: altura {x[0]*100:+5.1f} radio {x[1]*100:5.1f}  "
              f"(faltan {err[0]*100:+5.1f}, {err[1]*100:+5.1f} cm)",flush=True)
        if abs(err[0])<0.015 and abs(err[1])<0.02:
            print("  LISTO",flush=True); break
        # jacobiano 2x2 medido en la postura ACTUAL: cambia bastante con ella
        D=35; Jm=np.zeros((2,2))
        for k,j in enumerate(J2):
            v=int(np.clip(cur[j]+D,lim[j][0]+30,lim[j][1]-30))
            rob.bus.write("Goal_Position",j,v,normalize=False); time.sleep(0.55)
            Jm[:,k]=(estado()-x)/(v-cur[j] if v!=cur[j] else 1)
            rob.bus.write("Goal_Position",j,cur[j],normalize=False); time.sleep(0.55)
        if abs(np.linalg.det(Jm))<1e-12:
            print("  jacobiano degenerado; paro",flush=True); break
        d=np.linalg.solve(Jm,err)
        esc=min(1.0, PASO_MAX/max(abs(d).max(),1e-9))
        for k,j in enumerate(J2):
            cur[j]=int(np.clip(cur[j]+d[k]*esc,lim[j][0]+30,lim[j][1]-30))
            rob.bus.write("Goal_Position",j,cur[j],normalize=False)
        time.sleep(0.9)
    x=estado()
    ok = 0.075<x[0]<0.155 and 0.24<x[1]<0.325
    print(f"{'FINAL' if ok else 'NO CONVERGIO'} altura {x[0]*100:+.1f} cm, "
          f"radio {x[1]*100:.1f} cm; par MANTENIDO",flush=True)
    if not ok:
        for j in ARM:
            try: rob.bus.write("Torque_Enable",j,0,normalize=False)
            except Exception: pass
        print("  brazo SUELTO para colocarlo a mano",flush=True)
        sys.exit(1)
finally:
    try: rob.bus.disconnect(disable_torque=False)
    except Exception: pass
sys.stdout.flush()
