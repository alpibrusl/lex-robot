#!/bin/zsh
# Grabar demostraciones de agarre con teclado, para entrenar una politica.
#
# El angulo de la TORRE no puede cambiar entre grabar y ejecutar -- la guia de
# XLeRobot es tajante: si cambia, la politica no funciona o se degrada. Queda
# fijado aqui para poder reponerlo:  pan 1508, tilt 3386.
#
# Teclas: control ARTICULAR, un servo por pareja de teclas. Fila de arriba
# suma, fila de casa resta, de izquierda a derecha de la base a la pinza:
#
#     w / s   girar la base        y / h   muñeca arriba/abajo
#     e / d   hombro               u / j   girar la muñeca
#     t / g   codo                 i / k   abrir/cerrar la pinza
#
#   No se usan q, r, n, esc ni las flechas: son de lerobot-record (siguiente
#   episodio, repetir, salir) y los dos escuchas reciben todas las teclas.
#
#   Se combinan pulsando a la vez (e+t sube hombro y codo en el mismo
#   fotograma). Shift = cuarto de velocidad, para el agarre fino.
#
# Por que no el teclado cartesiano de lerobot (keyboard_ee): emite deltas
# x/y/z y el brazo solo entiende claves `<motor>.pos`. Nadie traduce en medio,
# asi que el diccionario llega vacio al bus y revienta (StopIteration en
# sync_write). La traduccion existe pero pide un URDF que no viene en el
# paquete, y da 4 mandos para 5 ejes: la muñeca la elegiria la cinematica
# inversa, no tu. Ver scripts/teclado_articular.py.
#
# Un solo brazo a proposito: la guia lo recomienda para coger y colocar, porque
# con menos servos y menos camaras la politica aprende bastante mejor.
set -a; source deploy/mac/xlerobot.env.example; set +a
P=/Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin

EPISODIOS=${EPISODIOS:-5}
SEGUNDOS=${SEGUNDOS:-25}
TAREA=${TAREA:-"coge la estrella de madera"}

$P/python scripts/grabar_teclado.py \
  --robot.type=so101_follower \
  --robot.port=/dev/cu.usbmodem5B610332201 \
  --robot.id=xle_right \
  --robot.max_relative_target=12.0 \
  --robot.cameras="{ head: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 15}, wrist: {type: opencv, index_or_path: 1, width: 640, height: 480, fps: 15} }" \
  --teleop.type=teclado_articular \
  --display_data=false \
  --dataset.repo_id=local/xle_estrella \
  --dataset.root=$HOME/lex-robot-datasets/xle_estrella \
  --dataset.single_task="$TAREA" \
  --dataset.num_episodes=$EPISODIOS \
  --dataset.episode_time_s=$SEGUNDOS \
  --dataset.push_to_hub=false
