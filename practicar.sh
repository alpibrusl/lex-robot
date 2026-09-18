#!/bin/zsh
# Practicar con el teclado SIN grabar nada. Se puede dejar corriendo.
#
#     w / s   girar la base        y / h   muñeca arriba/abajo
#     e / d   hombro               u / j   girar la muñeca
#     t / g   codo                 i / k   abrir/cerrar la pinza
#
#   Se combinan pulsando a la vez. Shift = cuarto de velocidad.
#   Esc o Ctrl-C para salir. El brazo se queda sujeto, no se desploma.
#
# Sin camaras y sin conjunto de datos: esto no graba, solo mueve.
# Al terminar, para dejar los servos libres:  python scripts/soltar_servos.py
#
# LANZALO DESDE TU TERMINAL. El permiso de Accesibilidad lo tiene Terminal,
# no el proceso de Claude; si lo lanzas desde ahi, el script te lo dira.
cd "$(dirname "$0")"
exec /Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin/python scripts/practicar_teclado.py "$@"
