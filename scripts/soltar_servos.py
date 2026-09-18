"""Soltar el par de los brazos, para dejar el robot en reposo.

NO toca la torre a proposito: sostiene la camara en el angulo con el que se
grabaron las demostraciones (pan 1508 / tilt 3386). Si se suelta y cae, ese
angulo se pierde y las demostraciones dejan de valer para entrenar.

Antes de soltar informa de postura y temperatura, porque soltar un brazo en
alto es dejarlo caer.
"""

import sys
import time

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

# El lado se identifica por los auxiliares de cada bus, no por la etiqueta:
# torre (ids 7,8) = izquierdo, ruedas (ids 9,10) = derecho.
BRAZOS = {
    "izquierdo": "/dev/cu.usbmodem5B610332201",
    "derecho": "/dev/cu.usbmodem5B3D0437151",
}
EJES = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


INTENTOS = 3


def soltar(nombre: str, puerto: str) -> bool:
    """Reintenta: este bus suelta SerialException de vez en cuando.

    Visto tres veces hoy en el puerto del brazo izquierdo, el que comparte
    linea con la torre: "device reports readiness to read but returned no
    data". Al reintentar funciona. Dejar el brazo con par por un fallo
    pasajero de lectura no es aceptable en el guion que sirve justo para
    dejarlo seguro.
    """
    for intento in range(1, INTENTOS + 1):
        if _soltar_una_vez(nombre, puerto, intento):
            return True
        if intento < INTENTOS:
            time.sleep(1.0)
    print(f"  {nombre}: NO SE PUDO SOLTAR en {INTENTOS} intentos -- revisalo a mano")
    return False


def _soltar_una_vez(nombre: str, puerto: str, intento: int) -> bool:
    motores = {n: Motor(i + 1, "sts3215", MotorNormMode.RANGE_M100_100) for i, n in enumerate(EJES)}
    bus = FeetechMotorsBus(port=puerto, motors=motores)
    try:
        bus.connect()
    except Exception as e:
        print(f"  {nombre}: no responde ({type(e).__name__}), intento {intento}")
        return False

    try:
        for eje in EJES:
            try:
                pos = int(bus.read("Present_Position", eje, normalize=False))
                tmp = int(bus.read("Present_Temperature", eje, normalize=False))
                print(f"    {eje:14s} pos={pos:5d}  {tmp:2d} C")
            except Exception:
                print(f"    {eje:14s} (sin lectura)")
        # Soltar explicitamente y RELEER. Fiarse del indicador de disconnect
        # no basta: en una prueba dijo "soltado" y los seis ejes seguian con
        # par puesto. Un guion cuyo unico trabajo es soltar no puede cantar
        # victoria sin mirar.
        bus.disable_torque()
        quedan = [e for e in EJES if int(bus.read("Torque_Enable", e, normalize=False))]
        bus.disconnect(disable_torque=True)
        if quedan:
            print(f"  {nombre}: SIGUEN CON PAR: {', '.join(quedan)} -- no te fies, revisalo")
            return False
        print(f"  {nombre}: par soltado y COMPROBADO (0 de {len(EJES)} ejes con par)")
        return True
    except Exception as e:
        print(f"  {nombre}: fallo al soltar en el intento {intento} ({type(e).__name__})")
        try:
            bus.disconnect(disable_torque=True)
        except Exception:
            pass
        return False


def main() -> int:
    sueltos = 0
    for nombre, puerto in BRAZOS.items():
        print(f"\nBrazo {nombre} ({puerto}):")
        sueltos += soltar(nombre, puerto)
    print(f"\n{sueltos} de {len(BRAZOS)} brazos sueltos. La TORRE no se ha tocado:")
    print("sostiene la camara en el angulo con el que grabaste.")
    return 0 if sueltos else 1


if __name__ == "__main__":
    raise SystemExit(main())
