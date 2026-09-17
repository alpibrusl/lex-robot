"""Sondear la mesa SIN cinematica inversa.

La version con IK fallaba por dos sitios: pedia desplazamientos laterales que la
IK resolvia con giros enormes (o no resolvia), y encadenaba destinos desde la
pose alcanzada, asi que el brazo derivaba hasta replegarse contra su propia base
y tomo por mesa 6 contactos contra si mismo.

Aqui no hace falta IK. shoulder_pan barre un arco HORIZONTAL: eso da la
separacion lateral. Y al bajar da igual si el descenso es recto, porque solo se
registra DONDE toco, no como llego. Una articulacion por movimiento, sin
solucionador de por medio.
"""
import os, sys, time, numpy as np
from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.model.kinematics import RobotKinematics

PORT=os.environ.get("PROBE_PORT","/dev/cu.usbmodem5B610332201")
PID=os.environ.get("PROBE_ID","xle_right")
ARM=["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]
PAN_OFFSETS=(0,-140,+140,-280,+280)      # ticks: el arco lateral
PASO=18                                   # ticks de bajada por paso
MAX_PASOS=70
kin=RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],joint_names=ARM,
                    target_frame_name="gripper_frame_link")
rob=SO101Follower(SO101FollowerConfig(port=PORT,id=PID)); rob.bus.connect()
def fk():
    deg=rob.bus.sync_read("Present_Position",num_retry=3)
    T=np.asarray(kin.forward_kinematics(np.array([float(deg[j]) for j in ARM])),float)
    return T[:3,3]
def carga():
    return float(max(int(rob.bus.read("Present_Load",j,normalize=False))&0x3FF
                     for j in ("shoulder_lift","elbow_flex")))
def raw(j): return int(rob.bus.read("Present_Position",j,normalize=False))
def ir(j,v): rob.bus.write("Goal_Position",j,int(v),normalize=False,num_retry=3)
try:
    p=fk(); print(f"pinza en ({p[0]:+.3f},{p[1]:+.3f},{p[2]:+.3f}) m",flush=True)
    for j in ARM: rob.bus.write("Torque_Enable",j,1,normalize=False)
    inicio={j:raw(j) for j in ARM}
    lim={j:(int(rob.bus.read("Min_Position_Limit",j,normalize=False)),
            int(rob.bus.read("Max_Position_Limit",j,normalize=False))) for j in ARM}
    for j in ARM: ir(j,inicio[j])
    time.sleep(0.8)
    base=max(carga() for _ in range(5)); UMBRAL=base+150
    print(f"carga en vacio {base:.0f}; contacto si supera {UMBRAL:.0f}",flush=True)
    # que sentido de shoulder_lift BAJA la pinza? se mide, no se supone
    z0=fk()[2]
    ir("shoulder_lift",np.clip(inicio["shoulder_lift"]+40,*lim["shoulder_lift"]))
    time.sleep(0.9); sube=fk()[2]-z0
    ir("shoulder_lift",inicio["shoulder_lift"]); time.sleep(0.9)
    SENTIDO=-1 if sube>0 else +1
    print(f"  +40 ticks de shoulder_lift mueve z {sube*100:+.1f} cm "
          f"-> para bajar uso {SENTIDO:+d}",flush=True)
    puntos=[]
    for k,off in enumerate(PAN_OFFSETS):
        for j in ARM: ir(j,inicio[j])
        time.sleep(1.0)
        pan=int(np.clip(inicio["shoulder_pan"]+off,*lim["shoulder_pan"]))
        ir("shoulder_pan",pan); time.sleep(1.2)
        lift=inicio["shoulder_lift"]; tocado=None
        for _ in range(MAX_PASOS):
            lift=int(np.clip(lift+SENTIDO*PASO,lim["shoulder_lift"][0]+30,
                             lim["shoulder_lift"][1]-30))
            ir("shoulder_lift",lift); time.sleep(0.35)
            c=carga()
            if c>UMBRAL:
                q=fk(); tocado=(float(q[0]),float(q[1]),float(q[2]))
                print(f"  pan {off:+5d}: CONTACTO en ({q[0]:+.3f},{q[1]:+.3f},"
                      f"{q[2]:+.3f}) carga {c:.0f}",flush=True)
                puntos.append(tocado); break
            if lift in (lim["shoulder_lift"][0]+30,lim["shoulder_lift"][1]-30): break
        if tocado is None: print(f"  pan {off:+5d}: sin contacto",flush=True)
        ir("shoulder_lift",inicio["shoulder_lift"]); time.sleep(1.0)
    for j in ARM: ir(j,inicio[j])
    time.sleep(1.2)
    if len(puntos)>=3:
        P=np.array(puntos); ext=P.max(0)-P.min(0)
        print(f"\n{len(puntos)} contactos, extension {ext[0]*100:.1f} x {ext[1]*100:.1f} cm")
        if min(ext[0],ext[1])<0.03:
            print("demasiado alineados para un plano; no escribo nada"); sys.exit(3)
        # Un contacto sobre un objeto (el nivel son 2 cm) es un atipico que
        # inclina el plano entero sin delatarse: el residuo sube un poco y el
        # ajuste sigue pareciendo razonable. Se ajusta, se mira quien se sale, y
        # se reajusta sin el -- diciendolo, no callandolo.
        def ajusta(Q):
            c=Q.mean(0); _u,_s,vt=np.linalg.svd(Q-c); n=vt[2]
            if n[2]<0: n=-n
            return c,n
        c,n=ajusta(P)
        for _ in range(2):
            r=np.abs((P-c)@n)
            if len(P)<=3: break
            med=float(np.median(r))
            fuera=r>max(3*med,0.006)
            if not fuera.any(): break
            print(f"  descarto {int(fuera.sum())} contacto(s) a "
                  f"{', '.join(f'{v*1000:.0f}mm' for v in r[fuera])} del plano "
                  "(objeto encima de la mesa?)",flush=True)
            P=P[~fuera]; c,n=ajusta(P)
        tilt=np.degrees(np.arccos(np.clip(abs(n[2]),-1,1)))
        res=np.abs((P-c)@n)
        print(f"PLANO: normal ({n[0]:+.3f},{n[1]:+.3f},{n[2]:+.3f}) -> {tilt:.1f} grados")
        print(f"  pasa por ({c[0]:+.3f},{c[1]:+.3f},{c[2]:+.3f}) m")
        print(f"  planitud: residuo max {res.max()*1000:.1f} mm")
        import json; json.dump({"points":P.tolist(),"points_all":puntos,"normal":n.tolist(),"centroid":c.tolist(),
                                "tilt_deg":float(tilt),"max_resid_mm":float(res.max()*1000)},
                               open("/tmp/table_touch.json","w"),indent=2)
        print("  guardado /tmp/table_touch.json")
    else: print(f"\nsolo {len(puntos)} contactos")
finally:
    try: rob.bus.disconnect()
    except Exception: pass
sys.stdout.flush()
