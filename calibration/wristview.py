#!/usr/bin/env python
"""Visor en vivo de la camara de la muneca, con aviso de deteccion del tablero.

Sin esto, encuadrar el tablero con la camara de la muneca es una loteria: quien
mueve el brazo no ve lo que enfoca. En una sesion entraron CERO vistas en 297 s
-- el brazo estaba quieto el 100% del tiempo y el tablero se detectaba el 0%.

Sirve una pagina con el video y un rotulo grande: VERDE si las 54 esquinas estan
dentro del cuadro, ROJO si no. Asi se coloca el brazo mirando la pantalla.

Cuando el tablero lleva --hold segundos seguidos detectado, FIJA EL PAR en esa
pose. Eso resuelve el relevo: sin ello el brazo se vence en cuanto la persona lo
suelta, y la pose buena se pierde antes de poder usarla. Con el par fijo se
puede cerrar el visor y lanzar 'handeye.py auto' sin que el brazo se mueva.
"""

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import cv2
import numpy as np

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex",
       "wrist_flex", "wrist_roll", "gripper"]
PORTS = {
    "right": "usb-1a86_USB_Single_Serial_5B61033220-if00",
    "left": "usb-1a86_USB_Single_Serial_5B3D045476-if00",
}
WRIST_CAM = {"right": "/dev/video2", "left": "/dev/video4"}
NX, NY = 9, 6

estado = {"jpeg": None, "ok": False, "fijado": False, "desde": None}
lock = threading.Lock()

# Un solo JPEG refrescado por JS en vez de multipart/x-mixed-replace: el flujo
# MJPEG lo rechazaban algunos navegadores como imagen truncada.
PAGINA = b"""<!doctype html><meta charset=utf-8>
<title>camara de la muneca</title>
<style>
 body{margin:0;background:#111;color:#eee;font:16px system-ui;text-align:center}
 img{max-width:100%;height:auto;display:block;margin:0 auto}
</style>
<img id=v>
<p><button onclick="fetch('/soltar')">soltar (volver a par blando)</button></p>
<script>
const v = document.getElementById('v');
let n = 0, cargando = false;
function tick() {
  if (cargando) return;
  cargando = true;
  const i = new Image();
  i.onload = () => { v.src = i.src; cargando = false; };
  i.onerror = () => { cargando = false; };
  i.src = '/frame.jpg?n=' + (n++);
}
setInterval(tick, 120); tick();
</script>
"""


def bucle(a):
    from lerobot.motors import Motor, MotorCalibration, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus
    raw = json.loads((Path.home() / ".cache/huggingface/lerobot/calibration"
                      / "robots/so_follower" / f"xle_{a.arm}.json").read_text())
    bus = FeetechMotorsBus(
        port=f"/dev/serial/by-id/{PORTS[a.arm]}",
        motors={j: Motor(i + 1, "sts3215", MotorNormMode.DEGREES)
                for i, j in enumerate(ARM)},
        calibration={n: MotorCalibration(**v) for n, v in raw.items()})
    bus.connect(handshake=False)
    cap = cv2.VideoCapture(WRIST_CAM[a.arm], cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    # Par BLANDO de entrada: aguanta el peso del brazo pero cede a la mano. Ni
    # soltarlo (se vence y hay que volver a colocarlo) ni dejarlo firme (no se
    # puede mover). Se endurece solo al detectar el tablero.
    pose0 = {j: float(bus.read("Present_Position", j)) for j in ARM}
    for j in ARM:
        bus.write("Torque_Limit", j, a.blando, normalize=False)
    bus.sync_write("Goal_Position", pose0)
    for j in ARM:
        bus.write("Torque_Enable", j, 1)
    print(f"par blando ({a.blando}): el brazo se mueve a mano sin caerse",
          flush=True)
    desde = None
    gracia = 0.0
    try:
        while True:
            ok, f = cap.read()
            if not ok:
                time.sleep(0.05)
                continue
            g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
            found, c = cv2.findChessboardCorners(
                g, (NX, NY),
                cv2.CALIB_CB_ADAPTIVE_THRESH + cv2.CALIB_CB_NORMALIZE_IMAGE)
            if found:
                cv2.drawChessboardCorners(f, (NX, NY), c, True)
                desde = desde or time.time()
            else:
                desde = None

            fijado = estado["fijado"]
            if estado.get("soltar"):
                with lock:
                    estado["soltar"] = False
                    estado["fijado"] = False
                pose = {j: float(bus.read("Present_Position", j)) for j in ARM}
                for j in ARM:
                    bus.write("Torque_Limit", j, a.blando, normalize=False)
                bus.sync_write("Goal_Position", pose)
                fijado = False
                desde = None
                # Sin este margen se vuelve a fijar a los 2 s, porque el tablero
                # sigue a la vista: da la sensacion de que el boton no hace nada.
                gracia = time.time() + a.gracia
                print(f"par blando otra vez ({a.gracia:.0f} s sin fijar)",
                      flush=True)
            if (found and not fijado and desde is not None
                    and time.time() > gracia
                    and time.time() - desde >= a.hold):
                pose = {j: float(bus.read("Present_Position", j)) for j in ARM}
                for j in ARM:
                    bus.write("Torque_Limit", j, a.torque, normalize=False)
                bus.sync_write("Goal_Position", pose)   # sin tiron
                for j in ARM:
                    bus.write("Torque_Enable", j, 1)
                with lock:
                    estado["fijado"] = True
                fijado = True
                print("POSE FIJADA por los servos — ya puedes soltar", flush=True)

            if fijado:
                txt, col = "POSE FIJADA - ya puedes soltar", (80, 220, 80)
            elif time.time() < gracia:
                txt, col = (f"SUELTO - colocalo ({gracia - time.time():.0f}s)",
                            (60, 200, 235))
            elif found:
                falta = max(0.0, a.hold - (time.time() - desde))
                txt, col = (f"TABLERO COMPLETO - no te muevas ({falta:.1f}s)",
                            (80, 220, 80))
            else:
                txt, col = "NO SE VE ENTERO - separate o inclina", (60, 60, 235)
            cv2.rectangle(f, (0, 0), (f.shape[1], 64), (20, 20, 20), -1)
            cv2.putText(f, txt, (16, 44), cv2.FONT_HERSHEY_SIMPLEX, 1.1, col, 3)

            enc, buf = cv2.imencode(".jpg", f, [cv2.IMWRITE_JPEG_QUALITY, 70])
            if enc:
                with lock:
                    estado["jpeg"] = buf.tobytes()
                    estado["ok"] = bool(found)
    finally:
        cap.release()
        # NOT a bare disconnect(): lerobot's default writes Torque_Enable=0 to
        # every motor, which soltaria justo la pose que acabamos de fijar.
        bus.disconnect(disable_torque=False)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/soltar":
            with lock:
                estado["soltar"] = True
            self.send_response(200); self.end_headers()
            self.wfile.write(b"ok"); return
        if self.path.startswith("/frame.jpg"):
            with lock:
                j = estado["jpeg"]
            if not j:
                self.send_response(503); self.end_headers(); return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(j)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(j)
            except (BrokenPipeError, ConnectionResetError):
                return
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(PAGINA)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--arm", choices=PORTS, default="right")
    p.add_argument("--port", type=int, default=8731)
    p.add_argument("--hold", type=float, default=2.0,
                   help="segundos de deteccion seguida antes de fijar el par")
    p.add_argument("--torque", type=int, default=350)
    p.add_argument("--gracia", type=float, default=12.0,
                   help="segundos sin fijar tras pulsar soltar")
    p.add_argument("--blando", type=int, default=170,
                   help="par mientras se coloca el brazo a mano")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    a = p.parse_args()
    threading.Thread(target=bucle, args=(a,), daemon=True).start()
    print(f"visor en http://localhost:{a.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
