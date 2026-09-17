#!/usr/bin/env python3
"""Tocar la mesa SIN forzar el servo: bajar el limite de par y mirar si llega.

Detectar el contacto por CARGA obliga a empujar hasta que la carga sube, y eso
llevo al servo del hombro a su enclavamiento de sobrecarga dos veces (52 C
contra 38-40 de sus companeros). Hacer el empuje "mas suave" -- pasos finos,
umbral mas bajo, retirada inmediata -- lo mitiga pero no lo arregla: el servo
sigue teniendo permiso para forzar.

Con Torque_Limit bajo el servo NO PUEDE sobrecargarse. Deja de empujar al
encontrar resistencia, y el contacto se nota porque no llega a la posicion
ordenada. El error de seguimiento es la senal, y el par nunca pasa del limite
puesto. Mas gentil y mas fiable a la vez: no depende de distinguir un salto de
carga de la subida gradual por gravedad, que es lo que dio 3 contactos falsos
cerca de la extension maxima.
"""
import time

TORQUE_SONDEO = 260      # de 1000; suficiente para mover el brazo, no para forzar
ERROR_CONTACTO = 22      # ticks de retraso que se consideran "no llega"
PASO = 12
MAX_PASOS = 110


class LimitePar:
    """Baja el limite de par mientras se sondea, y lo restaura siempre."""

    def __init__(self, bus, joints, limite=TORQUE_SONDEO):
        self.bus, self.joints, self.limite = bus, joints, limite
        self.previo = {}

    def __enter__(self):
        for j in self.joints:
            try:
                self.previo[j] = int(self.bus.read("Torque_Limit", j, normalize=False))
                self.bus.write("Torque_Limit", j, self.limite, normalize=False)
            except Exception:
                pass
        return self

    def __exit__(self, *exc):
        for j, v in self.previo.items():
            try:
                self.bus.write("Torque_Limit", j, v, normalize=False)
            except Exception:
                pass
        return False


def bajar_hasta_tocar(bus, joint, sentido, limites, paso=PASO,
                      max_pasos=MAX_PASOS, error=ERROR_CONTACTO, espera=0.33):
    """Bajar `joint` hasta que deje de seguir la orden. Devuelve True si toco.

    Requiere estar dentro de un `LimitePar`: sin el, el servo fuerza en vez de
    rendirse y esta deteccion no se dispara hasta haberlo castigado.
    """
    lo, hi = limites
    meta = int(bus.read("Present_Position", joint, normalize=False))
    for _ in range(max_pasos):
        meta = int(min(max(meta + sentido * paso, lo + 30), hi - 30))
        bus.write("Goal_Position", joint, meta, normalize=False)
        time.sleep(espera)
        real = int(bus.read("Present_Position", joint, normalize=False))
        if abs(meta - real) > error:
            # dejar de insistir: la orden se pone donde el servo SI esta
            bus.write("Goal_Position", joint, real, normalize=False)
            time.sleep(0.2)
            return True
        if meta in (lo + 30, hi - 30):
            return False
    return False
