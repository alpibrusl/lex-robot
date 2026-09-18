#!/bin/zsh
# Grabar demostraciones de agarre con teclado, para entrenar una politica.
#
#   ./grabar_demos.sh                 el brazo izquierdo (por defecto)
#   BRAZO=derecho ./grabar_demos.sh   el otro
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
# con menos servos y menos camaras la politica aprende bastante mejor. Por eso
# cada brazo graba en SU conjunto: mezclar los dos en uno solo confunde a la
# politica, que no tiene forma de saber cual esta viendo.
set -a; source deploy/mac/xlerobot.env.example; set +a
P=/Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin

# Los perfiles de calibracion estan CRUZADOS respecto al lado fisico y es a
# proposito: `xle_right` es el perfil del brazo IZQUIERDO. Son claves de
# busqueda; lo que importa es que cada puerto reciba el perfil de la EEPROM de
# sus propios servos. El lado se reconoce por los auxiliares del bus: torre
# (ids 7,8) = izquierdo, ruedas (ids 9,10) = derecho.
BRAZO=${BRAZO:-izquierdo}
case $BRAZO in
  izquierdo) PUERTO=/dev/cu.usbmodem5B610332201; PERFIL=xle_right; MUNECA=1 ;;
  derecho)   PUERTO=/dev/cu.usbmodem5B3D0437151; PERFIL=xle_left;  MUNECA=2 ;;
  *) echo "BRAZO debe ser 'izquierdo' o 'derecho', no '$BRAZO'" >&2; exit 1 ;;
esac

EPISODIOS=${EPISODIOS:-5}
SEGUNDOS=${SEGUNDOS:-25}
TAREA=${TAREA:-"coge la estrella de madera"}
# El izquierdo conserva el nombre de siempre: ahi estan los episodios ya grabados.
if [ "$BRAZO" = "izquierdo" ]; then CONJUNTO=${CONJUNTO:-xle_estrella}
else CONJUNTO=${CONJUNTO:-xle_estrella_derecho}; fi

echo "Brazo $BRAZO ($PUERTO, perfil $PERFIL, muñeca en camara $MUNECA)"
echo "Conjunto: $HOME/lex-robot-datasets/$CONJUNTO   $EPISODIOS episodios de $SEGUNDOS s"

$P/python scripts/grabar_teclado.py \
  --robot.type=so101_follower \
  --robot.port=$PUERTO \
  --robot.id=$PERFIL \
  --robot.max_relative_target=12.0 \
  --robot.cameras="{ head: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 15}, wrist: {type: opencv, index_or_path: $MUNECA, width: 640, height: 480, fps: 15} }" \
  --teleop.type=teclado_articular \
  --display_data=false \
  --dataset.repo_id=local/$CONJUNTO \
  --dataset.root=$HOME/lex-robot-datasets/$CONJUNTO \
  --dataset.single_task="$TAREA" \
  --dataset.num_episodes=$EPISODIOS \
  --dataset.episode_time_s=$SEGUNDOS \
  --dataset.push_to_hub=false
