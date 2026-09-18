#!/bin/zsh
# Grabar demostraciones de agarre con teclado, para entrenar una politica.
#
# El angulo de la TORRE no puede cambiar entre grabar y ejecutar -- la guia de
# XLeRobot es tajante: si cambia, la politica no funciona o se degrada. Queda
# fijado aqui para poder reponerlo:  pan 1508, tilt 3386.
#
# Teclas (control CARTESIANO, la cinematica inversa reparte el trabajo entre
# articulaciones; no se mueven servos sueltos):
#   flechas        mover en X e Y
#   shift / shift derecho   bajar / subir
#   ctrl izq / ctrl der     cerrar / abrir la pinza
#
# Un solo brazo a proposito: la guia lo recomienda para coger y colocar, porque
# con menos servos y menos camaras la politica aprende bastante mejor.
set -a; source deploy/mac/xlerobot.env.example; set +a
P=/Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin

EPISODIOS=${EPISODIOS:-5}
SEGUNDOS=${SEGUNDOS:-25}
TAREA=${TAREA:-"coge la estrella de madera"}

$P/lerobot-record \
  --robot.type=so101_follower \
  --robot.port=/dev/cu.usbmodem5B610332201 \
  --robot.id=xle_right \
  --robot.max_relative_target=12.0 \
  --robot.cameras="{ head: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 15}, wrist: {type: opencv, index_or_path: 1, width: 640, height: 480, fps: 15} }" \
  --teleop.type=keyboard_ee \
  --display_data=false \
  --dataset.repo_id=local/xle_estrella \
  --dataset.root=$HOME/lex-robot-datasets/xle_estrella \
  --dataset.single_task="$TAREA" \
  --dataset.num_episodes=$EPISODIOS \
  --dataset.episode_time_s=$SEGUNDOS \
  --dataset.push_to_hub=false
