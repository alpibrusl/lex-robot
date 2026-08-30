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

## El Mac Studio: paso 1 hecho tambien, a 640x480

Medido 2026-08-29. **Es una calibracion distinta, no una copia de la del Pi**:
otra unidad fisica de camara y otra resolucion, y una calibracion solo vale a
su propia resolucion.

```
22 vistas, RMS 0.585 px, 640x480, cuadro 20.15 mm, indice 0
fx=358.8  fy=357.3  (fx/fy=1.00413)   FOV 83.5 grados
cx=339.7 (+3.1%)  cy=255.7 (+3.3%)
k1=+0.0981 k2=-0.1357 p1=+0.00170 p2=-0.00400 k3=+0.0415

normalizado (lo que guarda CameraModel):
  fx=0.56062  fy=0.74442  cx0=0.53074  cy0=0.53267
```
-> `head_intrinsics_mac_640x480.json`

**8 de 22 vistas pegadas al borde**, frente a 3 de 21 en la tanda del Pi. Esa
era exactamente la palanca que el apartado de abajo pedia apretar. Area entre
9,6% y 28,3%, o sea un factor ~1,7 en distancia.

Contraste independiente: la FOV por damero da 83,5 grados y la medida por
correlacion de fase (`LEX_XLE_CAMERA_FOV`) dio 85,2. Dos metodos distintos, 2%
de diferencia.

**Cuatro tandas independientes, 2026-08-29.** Las tandas SUELTAS no son
fiables, y eso no se arregla capturando mejor:

| tanda | RMS | vistas al borde | area | fx norm | FOV |
|---|---|---|---|---|---|
| 1 | 0,585 px | 8/22 | 9,6-28,3% | 0,56062 | 83,5 |
| 2 | **0,298 px** | 0/22 | 7,5-11,8% | 0,54646 | 84,9 |
| 3 | 0,434 px | 0/22 | 4,1-18,8% | 0,53409 | 86,2 |
| 4 (solo bordes) | 0,456 px | **13/22** | 5,6-22,0% | 0,51524 | 88,3 |

**El RMS no predice nada.** La tanda de menor RMS (0,298) es la peor: cero
vistas al borde y `k3` desbocado a +0,2482 frente a +0,04 de las demas. Menos
restricciones -> ajuste mas comodo -> RMS mas bajo. Sobreajuste, no calidad.

**Y una tanda dedicada a bordes NO aprieta la dispersion.** Se hizo justo para
eso, con 13/22 vistas al borde y los rangos x/y mas anchos de las cuatro, y la
dispersion entre tandas sueltas SUBIO del 4,8% (tres tandas) al 8,4% (cuatro).
La `fx` suelta baja monotonamente tanda tras tanda -- 0,56062, 0,54646, 0,53409,
0,51524 -- que es una deriva sistematica, no ruido. Con 22 vistas el ajuste
compensa focal contra distorsion de forma distinta cada vez, y no hay tecnica
de captura que lo evite.

### LA VARIABLE QUE MANDABA ERA EL TAMANO DEL TABLERO (2026-08-30)

Las cuatro primeras tandas se hicieron todas con las esquinas a **21-24 px**, y
de ahi salia el 8,4% de dispersion. Con el tablero **de pie y a ~24 cm**,
encarado por la torre con `aim_tower_at_board.py`, las esquinas pasan a **32 px**
y cambia todo:

| tanda | esquinas | fx propia | desvio del conjunto |
|---|---|---|---|
| 1-4 (lejos, 22 vistas c/u) | 21-24 px | 0,51524 - 0,56062 | hasta 5,6% |
| barrido de torre (7 vistas) | 32 px | 0,53994 | 1,1% |
| **5, a mano de cerca (22 vistas)** | **32 px** | **0,54632** | **0,05%** |

**Una sola tanda de cerca reproduce el conjunto de 117 vistas**, y con solo
4/22 vistas al borde -- que el propio script marca como "POCAS", despues de
haber gastado dos tandas enteras persiguiendo bordes sin ganar nada. **No era la
tecnica de captura ni la cobertura de bordes: era la localizacion de esquinas**,
que es justo lo que necesita la ventana 11x11 de `cornerSubPix`.

Es el mismo consejo que dan en el hilo de OpenCV sobre eye-to-hand con LeRobot
("el tablero deberia ocupar >50% de la imagen"), enunciado alli como cobertura
cuando la causa real es esta.

**No hay sesgo entre poblaciones**, asi que se funde todo:

| | vistas | fx | esquinas |
|---|---|---|---|
| solo lejos | 88 | 0,54508 | 27,4 px |
| solo cerca | 29 | 0,54651 | 31,5 px |
| **todas** | **117** | **0,54517** | 28,0 px |

0,26% entre cerca y lejos, 1,0 mm a 400 mm. Las tandas de lejos bailaban 8,4%
una a una pero su CONJUNTO acierta: era ruido, no sesgo, y fundir las rescata.

**Regla practica: o capturas de cerca, y con una tanda basta, o capturas de
lejos y necesitas fundir varias.**

### El ajuste conjunto es lo que hay que usar, y esta medido

`pool_intrinsics.py` funde las esquinas guardadas de todas las tandas ->
`head_intrinsics_mac_640x480.pooled.json`:

```
117 vistas, RMS 0.454 px, FOV 85.1 grados
fx=0.54517 fy=0.72347 cx0=0.53400 cy0=0.52051
k1=+0.0919 k2=-0.1347 p1=+0.00024 p2=-0.00114 k3=+0.0435
```

**Estabilidad medida por jackknife** (quitar una tanda entera y reajustar):

| | dispersion | a 400 mm |
|---|---|---|
| tandas sueltas | 8,4% (std 3,6%) | ~34 mm |
| conjunto de 4 tandas de lejos | 1,8% | ~7 mm |
| **conjunto de las 6** | **0,75%** | **~2,3 mm** |

Error estandar jackknife del conjunto: **0,56%**, unos 2,3 mm a 400 mm, desde
1,28% (5,1 mm) cuando solo estaban las cuatro tandas de lejos. Parte de ese
estrechamiento es mecanico -- quitar una de seis tandas retira menos datos que
una de cuatro -- pero el grueso viene de las esquinas a 32 px. Y meter
las 22 vistas de la tanda 4 -- cuyo ajuste propio daba 0,51524, un 5% por
debajo -- movio el conjunto solo un 0,24%. Esa es la razon para fundir: no es
que las capturas sean mejores, es que 88 vistas sujetan el ajuste y 22 no.

**Corolario practico: no busques la tanda perfecta, acumula tandas.** Las
esquinas se guardan siempre (tambien si el ajuste propio se rechaza), asi que
cada tanda nueva se suma al conjunto sin recapturar nada.

### Mover la CAMARA con el tablero quieto: probado, no funciono

`sweep_tower_intrinsics.py` mueve la torre pan/tilt para pasear el tablero por
el encuadre, sin que nadie sostenga nada. La idea es buena -- las vistas de
BORDE son las que faltan y a mano salen pocas -- pero la primera tanda
(2026-08-29) **aporto cero vistas**: 5 utiles de 19 objetivos, y las 5
descartadas despues por error de reproyeccion. Tres causas, todas medidas:

1. **Girar la camara no cambia la DISTANCIA.** El area se quedo en 3,1-7,7% y
   sin esa variacion el ajuste no separa focal de profundidad: su ajuste propio
   dio fx normalizada 3,92 (siete veces la real) y FOV 14,5 grados. Es el mismo
   modo de fallo degenerado que la primera tanda historica, con otro disfraz.
2. **El tablero estaba pequeno en el encuadre** (4,9% de area desde la pose de
   partida), asi que las esquinas se localizan mal y las 5 vistas cayeron al
   filtro de >1,5 px.
3. **La escala real de la torre es la mitad de la teorica**: 1 tick = 0,38 px
   medidos frente a 0,66 px que salen de 4096 ticks/vuelta -- lleva reduccion.
   Ademas el tilt tenia solo +41 ticks de margen hacia arriba, asi que los
   objetivos de la fila superior eran inalcanzables y 12 de 19 perdieron el
   tablero.

**Segundo intento, con las tres causas corregidas: tampoco.** Se acerco el
tablero (esquinas a 21,4 px, area 9,3%), se cambio el guardia de area a
SEPARACION ENTRE ESQUINAS -- que es lo que de verdad limita a cornerSubPix con
su ventana 11x11, y un tablero oblicuo tiene area pequena por escorzo aunque
sus esquinas esten bien separadas -- y los objetivos pasaron a calcularse con
el tamano del tablero y a descartarse si la torre no llega. Resultado: **2
vistas utiles**. La causa es MECANICA y no se arregla con codigo:

* **Arriba no llega.** El tilt vive a ~3356 con tope en 3400: **44 ticks de
  margen**. Toda la fila superior del encuadre pide tilt 3683-3744.
* **Abajo hay recorrido (-833) pero no tablero.** A corta distancia la
  geometria se va, y el propio cuerpo del robot (la cesta) entra en el
  encuadre.
* Queda una banda horizontal. En pan sobra recorrido (-1137/+2263), pero esas
  vistas saldrian todas a la misma altura y la misma distancia.

**Rendimiento: 2 vistas por barrido frente a 22 de una tanda a mano**, y encima
pidiendo que alguien mueva el tablero entre barridos. **Recomendacion: no
insistir por aqui** mientras el tilt siga aparcado en su tope. Lo desbloquearia
montar el tablero mas ALTO (que la camara tenga que mirar hacia abajo, usando
los 833 ticks disponibles) o recolocar el tope del tilt.

**Leccion de proceso:** `pool_intrinsics.py` informa ahora de los descartes POR
FICHERO. Sin eso el conjunto salia identico con y sin el barrido y parecia que
sumaba, cuando lo que pasaba es que el filtro lo tiraba entero en silencio.

### La distorsion: cuanto costaba ignorarla, y por que ya no se ignora

`src/camera.lex` **era** un pinhole puro y los coeficientes medidos arriba no
los usaba nadie. Esto es lo que costaba, medido sobre esta calibracion:

| radio normalizado | desplazamiento medio | maximo |
|---|---|---|
| 0,0-0,3 (centro) | 0,34 px | 1,22 px |
| 0,3-0,6 | 2,54 px | 5,62 px |
| 0,6-0,9 | 4,88 px | 8,20 px |
| 0,9+ (esquinas) | 4,76 px | 8,41 px |

Mediana 3,0 px sobre el encuadre, maximo 8,4 px (1,31% del ancho). Eso son
~1,3 grados de error de direccion y **a 400 mm de alcance, ~9 mm** — del mismo
orden que los 5,3-7,2 mm del mano-ojo, y **mayor que los ~2,3 mm de la focal**.
Es despreciable en el centro y crece hacia los bordes, que es justo donde
`project_to_plane` acaba mirando cuando el objeto no esta centrado.

**Corregido 2026-08-30.** `CameraModel` lleva ya `k1`/`k2`/`k3`/`p1`/`p2` y
`ray_direction` desdistorsiona antes de construir el rayo, por iteracion de
punto fijo (la inversa de Brown-Conrady no tiene forma cerrada). Cero en los
cinco = comportamiento identico al de antes, asi que una calibracion vieja
carga igual. Hay tres implementaciones de esta proyeccion en el repo —
`src/camera.lex`, `vision_reset_teleop.CameraModel` y la forma directa de
`camera_calibrate.project_world_to_pixel` — y `sidecar/test_camera_distortion.py`
las ata entre si y contra `cv2.undistortPoints`, con los coeficientes medidos
de esta unidad. La directa tambien la aplica: la usa `verify` para preguntar si
la calibracion predice la realidad, y sin distorsion mediria el pinhole contra
una lente distorsionada y reportaria un error que seria suyo.

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
