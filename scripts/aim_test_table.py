"""PRUEBA DE PUNTERIA, sin cinematica inversa.

Con la pinza EN EL AIRE, su pixel no sirve de referencia: el rayo la atraviesa y
corta la mesa mucho mas alla (paralaje). Pero apoyada en la mesa el paralaje
desaparece -- el rayo corta el plano justo donde ella esta. Asi que: bajar hasta
tocar, mirar donde se ve la pinza, y recorrer el camino pixel->3D. La diferencia
contra la cinematica es el error de punteria real, en milimetros, y no necesita
mover nada de sitio.
"""
import json, os, sys, time, numpy as np, cv2
from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.model.kinematics import RobotKinematics
ARM=["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]
ex=json.load(open("calibration/head_extrinsics_mesa.json"))
R=np.array([ex["right"],ex["down"],ex["forward"]],float); C=np.array(ex["pos"],float)
ins=json.load(open("calibration/head_intrinsics_mac_640x480.pooled.json"))
K=np.array(ins["K"],float); dist=np.array(ins["dist"],float).reshape(-1,1)
# Dos desfases DISTINTOS, y confundirlos era el error de la version anterior:
# la camara ve el centroide de la mancha de los dedos, y lo que toca la mesa es
# la punta. Comparar la retroproyeccion de la mancha contra el origen del marco
# mezclaba ambos y daba 13 cm de "error" que era en realidad el desfase.
BLOB=np.array(ex.get("blob_offset_m",[0,0,0]),float)
CONT=np.array(ex.get("contact_offset_m",[0,0,0]),float)
tc=json.load(open("calibration/table_plane_touch.json"))
n_pl=np.array(tc["normal"],float); c_pl=np.array(tc["centroid"],float)
def pixel_a_mesa(u,v):
    p=cv2.undistortPoints(np.array([[[u,v]]],np.float64),K,dist).reshape(2)
    d=R.T@(np.array([p[0],p[1],1.0])/np.linalg.norm([p[0],p[1],1.0]))
    den=float(d@n_pl)
    if abs(den)<1e-6: return None
    t=float((c_pl-C)@n_pl)/den
    return None if t<=0 else C+t*d
kin=RobotKinematics(urdf_path=os.environ["LEX_XLE_URDF_PATH"],joint_names=ARM,
                    target_frame_name="gripper_frame_link")
rob=SO101Follower(SO101FollowerConfig(port="/dev/cu.usbmodem5B610332201",id="xle_right"))
rob.bus.connect()
cap=cv2.VideoCapture(0); cap.set(3,640); cap.set(4,480); [cap.read() for _ in range(12)]
def gris():
    for _ in range(4): cap.read()
    ok,f=cap.read(); return cv2.cvtColor(f,cv2.COLOR_BGR2GRAY).astype(np.float32) if ok else None
def fk_T():
    deg=rob.bus.sync_read("Present_Position",num_retry=3)
    return np.asarray(kin.forward_kinematics(np.array([float(deg[j]) for j in ARM])),float)
def fk(): return fk_T()[:3,3]
def punto(off):
    T=fk_T(); return T[:3,:3]@off+T[:3,3]
def carga():
    return float(max(int(rob.bus.read("Present_Load",j,normalize=False))&0x3FF
                     for j in ("shoulder_lift","elbow_flex")))
def pinza_pixel():
    c=int(rob.bus.read("Present_Position","gripper",normalize=False))
    hi=int(rob.bus.read("Max_Position_Limit","gripper",normalize=False))
    t=int(min(c+700,hi-20)); a=gris()
    rob.bus.write("Torque_Enable","gripper",1,normalize=False); time.sleep(0.2)
    rob.bus.write("Goal_Position","gripper",t,normalize=False); time.sleep(1.4)
    b=gris()
    rob.bus.write("Goal_Position","gripper",c,normalize=False); time.sleep(1.2)
    if a is None or b is None: return None
    d=np.abs(b-a); d[d<12]=0
    m=cv2.morphologyEx((d>0).astype(np.uint8),cv2.MORPH_OPEN,np.ones((5,5),np.uint8))
    nn,_l,st,ce=cv2.connectedComponentsWithStats(m,8)
    if nn<2: return None
    i=max(range(1,nn),key=lambda z:st[z,cv2.CC_STAT_AREA])
    return (float(ce[i][0]),float(ce[i][1])) if st[i,cv2.CC_STAT_AREA]>=400 else None
try:
    for j in ARM: rob.bus.write("Torque_Enable",j,1,normalize=False)
    lo=int(rob.bus.read("Min_Position_Limit","shoulder_lift",normalize=False))
    hi=int(rob.bus.read("Max_Position_Limit","shoulder_lift",normalize=False))
    pan0=int(rob.bus.read("Present_Position","shoulder_pan",normalize=False))
    plo=int(rob.bus.read("Min_Position_Limit","shoulder_pan",normalize=False))
    phi=int(rob.bus.read("Max_Position_Limit","shoulder_pan",normalize=False))
    errs=[]
    for k,off in enumerate((0,-110,+110)):
        rob.bus.write("Goal_Position","shoulder_pan",int(np.clip(pan0+off,plo+30,phi-30)),
                      normalize=False); time.sleep(1.5)
        base=max(carga() for _ in range(4)); UMB=base+150
        lift=int(rob.bus.read("Present_Position","shoulder_lift",normalize=False))
        z0=fk()[2]
        rob.bus.write("Goal_Position","shoulder_lift",int(np.clip(lift+30,lo+30,hi-30)),
                      normalize=False); time.sleep(0.8)
        sgn=+1 if fk()[2]<z0 else -1
        rob.bus.write("Goal_Position","shoulder_lift",lift,normalize=False); time.sleep(0.8)
        toc=None
        hist=[]
        for _ in range(70):
            lift=int(np.clip(lift+sgn*14,lo+30,hi-30))
            rob.bus.write("Goal_Position","shoulder_lift",lift,normalize=False); time.sleep(0.33)
            cc=carga(); hist.append(cc)
            # Un umbral absoluto no distingue contacto de GRAVEDAD: cerca de la
            # extension maxima el par sobre shoulder_lift ya es alto y sube al
            # bajar, asi que cruza el umbral sin tocar nada (salieron 3 falsos
            # contactos seguidos, todos 2 cm por encima de la mesa). Un contacto
            # real SALTA; la gravedad sube poco a poco.
            salto=cc-min(hist[-4:-1]) if len(hist)>=4 else 0.0
            if cc>UMB and salto>250:
                toc=fk().copy()
                print(f"    contacto: carga {cc:.0f}, salto {salto:.0f} en 3 pasos",flush=True)
                break
        if toc is None: print(f"  punto {k+1}: sin contacto",flush=True); continue
        # Si el contacto no esta a la altura de la mesa, NO es la mesa. Los tres
        # primeros contactos salieron a -0.090..-0.100 con la mesa en -0.064: la
        # pinza estaba dentro de la cesta del carrito, 3 cm mas abajo, y el
        # "error de punteria" de 9.5 cm medido asi no significaba nada.
        # el que debe estar en el plano es el punto de CONTACTO, no el origen
        toc_c=punto(CONT)
        fuera=float((toc_c-c_pl)@n_pl)
        if abs(fuera)>0.015:
            print(f"  punto {k+1}: contacto {fuera*100:+.1f} cm respecto al plano de "
                  "la mesa -> NO es la mesa (cesta? objeto?). Descartado.",flush=True)
            rob.bus.write("Goal_Position","shoulder_lift",
                          int(np.clip(lift-sgn*90,lo+30,hi-30)),normalize=False)
            time.sleep(1.2); continue
        px=pinza_pixel()
        if px is None: print(f"  punto {k+1}: no veo la pinza apoyada",flush=True); continue
        vis=pixel_a_mesa(px[0],px[1])
        if vis is None: print(f"  punto {k+1}: el rayo no corta la mesa",flush=True); continue
        # la mancha esta en el aire aunque la punta toque, asi que su rayo NO
        # corta la mesa donde ella esta: se compara contra donde la cinematica
        # dice que esta la mancha, proyectado al plano por el mismo rayo.
        blob3=punto(BLOB)
        e=vis-blob3; lat=float(np.linalg.norm(e-n_pl*float(e@n_pl)))
        errs.append(float(np.linalg.norm(e)))
        print(f"  punto {k+1}: contacto a {fuera*100:+.1f} cm del plano; "
              f"mancha (cinematica) en ({blob3[0]:+.3f},{blob3[1]:+.3f},{blob3[2]:+.3f})",flush=True)
        print(f"            la camara la situa en ({vis[0]:+.3f},{vis[1]:+.3f},{vis[2]:+.3f})",flush=True)
        print(f"            ERROR {np.linalg.norm(e)*100:.1f} cm ({lat*100:.1f} lateral)",flush=True)
        # subir antes de girar
        rob.bus.write("Goal_Position","shoulder_lift",int(np.clip(lift-sgn*90,lo+30,hi-30)),
                      normalize=False); time.sleep(1.2)
    if errs:
        a_=np.array(errs)
        print(f"\nERROR DE PUNTERIA: media {a_.mean()*100:.1f} cm, "
              f"peor {a_.max()*100:.1f} cm, sobre {len(a_)} puntos",flush=True)
        print("-> " + ("SIRVE para agarrar (la pinza abre 3.5 cm)" if a_.mean()<0.025
              else "todavia no: supera media apertura de pinza"),flush=True)
finally:
    try: rob.bus.disconnect(disable_torque=False)  # si no, el brazo se cae al salir
    except Exception: pass
    cap.release()
sys.stdout.flush()
