# Calibración de la cámara del robot

Estado y procedimiento. Escrito para retomarlo mañana sin releer una sesión
entera.

## Dónde estamos

Paso **1 de 3** hecho.

| paso | estado | qué necesita |
|---|---|---|
| 1. Intrínsecos (el objetivo) | **hecho** — `head_intrinsics_1280x960.json` | tablero, pantalla o papel |
| 2. Extrínsecos (dónde está la cámara) | pendiente | torre apuntada y sujeta, tablero plano en un punto **medido** |
| 3. Verificación | pendiente | puntos conocidos que la calibración deba predecir |

Solo al terminar el 3 hay un `CameraModel` en el que confiar, y solo entonces
tiene sentido el motor de datos de #153: todo el bucle de auto-reset es
visión → `project_to_plane` → xyz → IK, y `project_to_plane` rechaza
imposibles geométricos pero **no** números equivocados (#150 riesgo 3).

## El resultado del paso 1

```
21 vistas, RMS 0.365 px, 1280x960, cuadro 20.15 mm, /dev/video0
fx=605.6  fy=604.4  (fx/fy=1.00203)   FOV 93.2 grados
cx=685.2 (+3.5%)   cy=490.7 (+1.1%)
k1=+0.0622 k2=-0.0906 p1=-0.00066 p2=+0.00088 k3=+0.0234

normalizado (lo que guarda CameraModel):
  fx=0.47313  fy=0.62956  cx0=0.53530  cy0=0.51110
```

El JSON lleva las 21x54 esquinas detectadas, así que **se puede reajustar o
ampliar sin volver a capturar**.

### La incertidumbre real es 4,6%, no 0,365 px

Tres tandas independientes dieron `fx` normalizado 0.49532 / 0.48165 / 0.47313
y FOV 90,5 / 92,1 / 93,2 grados. Esa dispersión del **4,6%** es el error
honesto; el RMS solo dice que el modelo explica las vistas que se le dieron.
A 400 mm de alcance son unos 18 mm.

La causa: solo 3 de 21 vistas llegaron a menos de 60 px del borde del encuadre.
La distorsión se mide en los bordes; sin datos ahí, el ajuste la compensa
moviendo la focal, y cada tanda la mueve distinto. **La palanca para apretarlo
son 8-10 vistas pegadas de verdad a bordes y esquinas**, y ahora se pueden
añadir a las 21 existentes.

## Cómo repetir el paso 1

```sh
python calibration/capture_intrinsics.py \
    --views 22 --settle 3.5 --square-mm 20.15 \
    --camera 0 --width 1280 --height 960 \
    --out calibration/head_intrinsics_1280x960.json
```

Mover el tablero entre capturas variando **tres** cosas: distancia, inclinación
(30-40 grados) y posición en el encuadre, **incluidas las esquinas**. Pararse en
seco antes de cada captura: las vistas movidas son lo que sube el RMS.

## Trampas ya pisadas, para no repetirlas

**Un RMS bajo no valida nada.** La primera tanda dio RMS 0.127 px con un FOV de
26 grados y k3=+163: 20 vistas idénticas, ajuste degenerado. El RMS bajo *era*
la señal del sobreajuste. Por eso el script comprueba FOV, distorsión y punto
principal, y rechaza aunque el RMS sea bueno.

**Cada resolución de esta cámara tiene un campo de visión distinto.** Medido con
el tablero como regla: a 640x480 ocupa el 14,89% del ancho, a 800x600/1024x768/
1280x960 el 13,1% y a 1920x1080 el 9,80%. No son recortes equivalentes.
**Una calibración solo vale a la resolución con la que se tomó.** Esta es de
1280x960, así que el sidecar tiene que correr a 1280x960.

**No alimentar al panel una relación de aspecto que no es la suya.** Poner el
monitor 16:9 a 1280x960 estiró los cuadrados un 30% (relación h/v 1,305). Eso
habría entrado en `fx` sin que el error de reproyección se enterara. El panel
siempre a su resolución nativa; la resolución de *captura* se cambia por
software.

**Medir el tablero con una regla, siempre.** El PNG se generó a 1920x1080 para
1:1, pero el valor bueno salió de medir entre las marcas: 201,5 mm / 10 = 20,15
mm. Coincidió con el paso de píxel de un panel de 14" 1920x1200 (0,157 mm/px),
lo que confirmó de paso que se mostraba al 100%.

**La torre deriva sola.** Medida moviéndose **174 ticks (~15 grados) en una
noche**, sin tocarla, porque va sin par. La cámara de cabeza va montada en ella.
Por eso el paso 2 empieza apuntando y sujetando, no al revés.

**`/tmp` se borra al reiniciar.** Se perdió una calibración entera por
guardarla ahí. Por eso este directorio está en el repo.

## Paso 2: extrínsecos

Orden obligado, y el primer punto es el que se olvida:

1. **Apuntar la torre a la zona de trabajo.** Ahora mismo la cámara mira a la
   habitación, no a ninguna superficie de trabajo. Calibrar la vista de una
   pared es trabajo tirado.
2. **Sujetarla**: `python sidecar/tower.py --port $LEX_XLE_LEFT_PORT --hold`.
   Límites ya medidos en esta unidad: tope mecánico real de tilt en 2483 ticks
   (no bajar de ahí), pan [1000, 2100] y tilt hasta 3400 *recorridos*, que no es
   lo mismo que medidos. Pasarse fuerza el cable USB de la cámara y nada del
   lado del servo lo detecta.
3. **Tablero plano** sobre la superficie, con su primera esquina interior en un
   punto **medido** en el marco del brazo. Un portátil abierto casi plano sirve;
   un monitor de escritorio no.
4. Ejecutar:

```sh
python sidecar/camera_calibrate.py extrinsics --camera 0 \
    --intrinsics calibration/head_intrinsics_1280x960.json \
    --board 9x6 --square-mm 20.15 --width 1280 --height 960 \
    --board-origin X Y Z --tower-port $LEX_XLE_LEFT_PORT \
    --out calibration/head_camera_model.json
```

**El error de reproyección de este paso NO valida `--board-origin`.** Si el
punto está mal medido, el ajuste sale perfecto y la respuesta está mal
exactamente en lo que te equivocaste. Medir ese punto dos veces.

## Paso 3: verificación

```sh
python sidecar/camera_calibrate.py verify \
    --model calibration/head_camera_model.json --point X Y Z
```

Poner objetos en sitios medidos y comprobar que las (u,v) predichas caen donde
están de verdad. Es lo único que valida la cadena entera, origen del tablero
incluido.

Después, la pose de la torre queda guardada en el bloque `tower` del modelo y
se comprueba antes de cada sesión desatendida con:

```sh
python sidecar/bus_preflight.py --tower-calib calibration/head_camera_model.json
```

## Mapa de cámaras (medido, no supuesto)

| dispositivo | cámara | cómo se estableció |
|---|---|---|
| `/dev/video0` | cabeza, en la torre | única vista que se mueve al mover la torre |
| `/dev/video2` | muñeca derecha | la pinza derecha la mueve 7,3x más que a video4 |
| `/dev/video4` | muñeca izquierda | la pinza izquierda la mueve 3,6x más que a video2 |

Están en `deploy/pi/xlerobot.env.example`.

## Pendiente de decidir

`LEX_XLE_CAMERA_WIDTH/HEIGHT` sigue en 640x480 en el env de la Pi, pero esta
calibración es de **1280x960**. Antes de usar el `CameraModel` hay que
cambiarlo, y el coste ya está medido: 23,4 ms por fotograma frente a 11,6, con
un presupuesto de 50 ms a 20 Hz.
