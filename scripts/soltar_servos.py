"""Soltar el par de los brazos, para dejar el robot en reposo.

NO toca la torre a proposito: sostiene la camara en el angulo con el que se
grabaron las demostraciones (pan 1508 / tilt 3386). Si se suelta y cae, ese
angulo se pierde y las demostraciones dejan de valer para entrenar.

Antes de soltar informa de postura y temperatura, porque soltar un brazo en
alto es dejarlo caer.
"""

import sys

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

BRAZOS = {
    "derecho": "/dev/cu.usbmodem5B610332201",
    "izquierdo": "/dev/cu.usbmodem5B3D0437151",
}
EJES = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


def soltar(nombre: str, puerto: str) -> bool:
    motores = {n: Motor(i + 1, "sts3215", MotorNormMode.RANGE_M100_100) for i, n in enumerate(EJES)}
    bus = FeetechMotorsBus(port=puerto, motors=motores)
    try:
        bus.connect()
    except Exception as e:
        print(f"  {nombre}: no responde ({type(e).__name__}); lo dejo como esta")
        return False

    try:
        for eje in EJES:
            try:
                pos = int(bus.read("Present_Position", eje, normalize=False))
                tmp = int(bus.read("Present_Temperature", eje, normalize=False))
                print(f"    {eje:14s} pos={pos:5d}  {tmp:2d} C")
            except Exception:
                print(f"    {eje:14s} (sin lectura)")
        # disable_torque=True es justo lo que queremos aqui, por una vez.
        bus.disconnect(disable_torque=True)
        print(f"  {nombre}: par SOLTADO")
        return True
    except Exception as e:
        print(f"  {nombre}: fallo al soltar ({type(e).__name__}: {e})")
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
