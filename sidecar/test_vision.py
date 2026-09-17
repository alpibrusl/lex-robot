"""Tests de la vision. Sin camara, sin modelo, sin robot.

Lo que se prueba es el FILTRO, que es donde esta el riesgo: con la luz apagada
el modelo no dijo "no veo nada", describio con seguridad "una pizarra" que no
existia. Una descripcion inventada suena igual que una buena, asi que la unica
defensa es no preguntar sobre una imagen inservible.
"""
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _img(valor, ruido=0.0, semilla=0):
    r = np.random.default_rng(semilla)
    a = np.full((480, 640, 3), valor, np.uint8)
    if ruido:
        a = np.clip(a.astype(np.int16) + r.normal(0, ruido, a.shape), 0, 255).astype(np.uint8)
    return a


def test_una_imagen_negra_se_rechaza():
    """El caso real: luz apagada, brillo medio bajo 12, y el modelo describio
    una pizarra inexistente."""
    from vision import calidad
    br, sd, vale = calidad(_img(0))
    assert not vale and br < 12


def test_una_imagen_casi_negra_tambien():
    from vision import calidad
    _br, _sd, vale = calidad(_img(6, ruido=1.5))
    assert not vale


def test_una_imagen_saturada_se_rechaza():
    """Brillante pero sin informacion: apuntar a una lampara o a una pared
    blanca. Pasa el filtro de brillo y no el de contraste."""
    from vision import calidad
    br, _sd, vale = calidad(_img(255))
    assert br > 12 and not vale


def test_una_escena_real_se_acepta():
    """Valores medidos en esta habitacion con la luz encendida: 84-109 de brillo
    medio y desviacion de ~60."""
    from vision import calidad
    br, sd, vale = calidad(_img(90, ruido=60, semilla=1))
    assert vale and br > 12 and sd > 8


@pytest.mark.parametrize("direccion,signo", [("derecha", +1), ("izquierda", -1)])
def test_las_direcciones_giran_al_lado_correcto(direccion, signo):
    from vision import GIRO
    assert GIRO[direccion] * signo > 0


def test_mirar_de_frente_no_gira_la_torre():
    """Preguntar "que ves" no debe tocar la torre: su angulo es parte de la
    calibracion de la camara, y moverla la invalida."""
    from vision import GIRO
    assert "frente" not in GIRO


def test_un_giro_completo_cabe_en_el_recorrido():
    """No pedir a la torre mas de lo que puede girar."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import tower
    from vision import GIRO
    recorrido = tower.DEFAULT_PAN_LIMITS[1] - tower.DEFAULT_PAN_LIMITS[0]
    assert max(abs(v) for v in GIRO.values()) < recorrido
