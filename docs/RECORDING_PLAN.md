# Plan de grabaciones

Qué grabar, en qué orden y por qué, para no improvisar. Pensado para demos por
teclado en el XLeRobot (`/control` + `/teach`), con un objeto que se coge con
una pinza. Las cifras de tamaño salen de los benchmarks de SO-101 de 2026
(unas 100 demos por tarea) y de la guía de teleoperación: empezar con 20-30,
entrenar, y escalar.

**Nada de imágenes en el repositorio.** Los fotogramas enseñan la casa. Los
episodios viven en `sidecar/taught/` (ignorado) o en la caché de lerobot; en el
repo solo van datos derivados.

## Antes de la primera grabación

- [ ] Brazo elegido y **desbloqueado** (el izquierdo necesita las medidas de la
      bandeja; ver `robot_geometry.json`). Comprobar que llega a la mesa.
- [ ] Objeto: algo que **no se rompa** (bote de plástico, tapón grande). El bote
      de tinta de cristal, cuando el agarre sea fiable.
- [ ] Pose de inicio guardada (`/teach` → "Set this as home"), igual en todas.
- [ ] Marca de cinta para cada posición. Cámaras sin tocar, luz fija.
- [ ] Frase de tarea decidida (abajo) y **sin cambiarla** dentro de una etapa.

## Etapas

| # | Qué | Episodios | Tarea (texto exacto) | Etiquetas |
|---|---|---|---|---|
| 0 | Prueba de tubería: coger en el centro. Se tiran | 3 | `pick up the object` | `test` |
| 1 | Posición fija P0 | 25 | `pick up the object` | `stage1`, `p0` |
| 2 | Cuadrícula 3x3, 5 por casilla, orden aleatorio | 45 | `pick up the object` | `stage2`, `p1`..`p9` |
| 3 | Variación: otra luz (10) y objeto distractor (10) | 20 | `pick up the object` | `stage3`, `light` / `distractor` |
| 4 | Recuperación: fallar a propósito y corregir | 12 | `pick up the object` | `stage4`, `recovery` |
| 5 | Coger y colocar en una marca (25), luego 3 destinos x 5 | 40 | `pick up the object and place it on the mark` | `stage5`, `place` |
| 6 | Para el verificador: 10 éxitos y 10 fallos **etiquetados** | 20 | la de la etapa | `verifier`, `ok` / `fail` |

Total: unos 165 episodios. **La etapa 0 mide cuánto cuesta una demo con
teclado**; si son 4 minutos, son 11 horas, y hay que recortar.

Notas por etapa:

- **0.** Sirve para comprobar grabar -> convertir (`teach_to_dataset.py`) ->
  ver en LeLab -> entrenar. Nadie aprende de estas.
- **1.** Primera política (ACT) y primera prueba real. Si aquí no funciona, la
  cuadrícula no lo arreglará.
- **2.** Marcar las casillas con cinta, 8-10 cm entre ellas, **dentro del
  alcance** del brazo (mirar `/control`: mapas del área permitida). Grabar en
  orden aleatorio, no casilla por casilla: si no, la luz y el cansancio se
  confunden con la posición.
- **4.** Solo después de la etapa 2. Es lo que más cuesta de conseguir sin
  demostrarlo (recuperación en SO-101: 3-31% según la política).
- **5.** El objeto empieza en la pinza o en la mesa; decidirlo una vez. Soltar
  es parte del episodio.
- **6.** **No se entrenan.** Sirven para medir al verificador contra etiquetas
  humanas (`episode_verifier.score()`): un verificador que siempre dice "éxito"
  puntúa bien en un conjunto mayormente exitoso y no sirve.

## Ejemplos concretos

Los 165 episodios, uno por fila, están en **`docs/recording_sequence.csv`**
(generado por `scripts/make_recording_sequence.py` con semilla fija, así que el
orden aleatorio no cambia). Cada fila trae el **nombre exacto** (`s2_p3_002`),
el prefijo que se escribe en la fila RECORD, la tarea, las etiquetas, dónde va el
objeto, la receta y las columnas para anotar el resultado. Se sigue por orden.

### Antes de empezar: elegir P0 y marcar las casillas

P0 es la casilla central, la que usan las etapas 1, 4 y 5. Se elige con el propio
robot, sin cinta métrica:

1. En `/control`, con el brazo elegido, lleva la punta de la pinza abierta hasta
   un punto cómodo de la mesa. La página da `reach` (adelante), `across`
   (lado, + = izquierda del robot) y `height` en cm.
2. **P0 debe tener reach entre 24 y 38 cm.** El área permitida llega a 45 cm y
   la fila de delante está 6 cm más allá de P0.
3. Marca ese punto en la mesa con cinta, y apunta `reach` y `across`.
4. Marca las otras 8 casillas con cinta a estas distancias de P0:

```
                       across:   -8 cm      0       +8 cm      (+ = izquierda del robot)
   lejos   reach +6 cm:           p7        p8        p9
           reach  0 cm:           p4        p5=P0     p6
   cerca   reach -6 cm:           p1        p2        p3
```

5. Cada punto tiene que ser alcanzable: lleva la pinza a cada uno en `/control`.
   Si alguno no llega, se corre P0 y se vuelven a marcar.
6. Para la etapa 5, una marca de cinta (el destino) a estas distancias de P0:
   `t0` reach 0, across -16 · `t1` reach +6, across -16 · `t2` reach -6,
   across -16 · `t3` reach 0, across -24.

### Recetas (teclas exactas)

Pasos de 2 cm para acercarse y de 1 cm para bajar: `+` multiplica por 2 y `-`
divide por 2 (empieza en 1 cm). Moverse de lado (`A`/`D`) gira un poco la
pinza; se corrige con `J`/`L`. Antes de la primera grabación (etapa 0) hay que
anotar **qué tecla de la muñeca (`I`/`K`) apunta la pinza hacia abajo** y
rellenarlo aquí: `TILT_DOWN = ___`.

**R-PICK** (coger):

1. Brazo en la pose de inicio (`H`), pinza abierta (`O`), `+` una vez (pasos de 2 cm).
2. Objeto en su casilla. **Espacio**: empieza la grabación.
3. Sobre el objeto: `W`/`S` y `A`/`D` hasta que la cámara de la muñeca lo vea
   centrado entre los dedos. Unas 4-8 pulsaciones.
4. Muñeca con la pinza hacia abajo (`TILT_DOWN`), si hace falta.
5. `-` una vez (pasos de 1 cm). Baja con `F` (mantenida) hasta que los dedos
   rodeen el bote a media altura: en la cámara de muñeca, el bote llena el
   hueco y el tapón queda por encima de los dedos.
6. `C`: cerrar. Cuenta "uno-mil-uno" sin tocar nada.
7. Sube con `R` (mantenida) unos 10 cm. Cuenta "uno-mil-uno" arriba.
8. **Espacio**: para y guarda. Lee el informe.
9. Vuelve a dejar el objeto en su casilla **con la mano, fuera del encuadre de las
   cámaras y sin grabar**. `O` y `H` para el siguiente.

**R-PLACE** (coger y colocar): como R-PICK hasta el paso 7, pero se sube solo
8 cm; luego se mueve con `A`/`D` (y `W`/`S`) hasta que el bote quede sobre la
marca, se baja con `F` hasta unos 1-2 cm por encima de ella, `O` para soltar,
cuenta "uno-mil-uno", se sube 8 cm con `R` y **Espacio**.

**R-RECOVER-A/B/C** (recuperación). Siempre **terminan con el objeto levantado**:

- **A, agarre alto:** cierra sobre el tercio superior del bote (el tapón), nota
  que va a caer, `O`, baja, vuelve a agarrar a media altura, sube.
- **B, objeto empujado:** mientras te acercas, empuja el bote unos 3 cm de
  lado con un dedo, recentra sobre él y coge como en R-PICK.
- **C, fallo:** cierra en el aire a unos 3 cm de un lado, `O`, desplázate de
  lado (`A`/`D`), baja otra vez, agarra, sube.

**R-FAIL-\*** (para el verificador, **no se entrenan**). Se anotan con la
etiqueta que ya trae la fila:

- **MISS:** cierra en el aire junto al objeto y sube.
- **DROP:** agarra bien, sube 5 cm y suelta con `O` para que caiga.
- **OFFTARGET:** coge bien y coloca el objeto a 6 cm o más de la marca.
- **ABORT:** coge, transporta y para la grabación antes de soltar.

### Condiciones de las etapas 3 y 6

- **Luz A:** persianas abiertas, luz de día, sin lámpara. **Luz B:** persianas
  cerradas y lámpara de mesa. Se graban las 5 de una luz seguidas, no una a una.
- **Distractor:** un segundo objeto (un destornillador o un cable enrollado) a
  10 cm a la izquierda o a la derecha del objeto, en el camino de la pinza pero
  sin tocarlo. La fila dice de qué lado.

## Reglas de cada demo

1. La misma pose de inicio, la misma luz, las cámaras sin tocar.
2. De 15 a 20 s, sin pausas largas. La misma estrategia (aproximación desde
   arriba, mismo orden de movimientos). La velocidad uniforme importa más que
   la perfección.
3. Después de grabar, leer el informe: frames, salto máximo entre frames y Hz
   conseguidos. Si hay un salto de más de 30 grados, o faltan muchos frames,
   **se borra**.
4. Un rechazo sano ronda el 5%. Por encima del 15% el problema es el protocolo,
   no el operador.
5. Anotar el motivo de cada descarte (hoja de abajo).

## Hoja de control

Una fila por episodio. Fuera del repo (o sin imágenes).

```
nombre, etapa, casilla, arm, objeto, tarea, duracion_s, frames, hz, salto_max, resultado(ok|fail), descarte(motivo), notas
pick_p1_001, 2, p1, right, tapon, "pick up the object", 17.2, 340, 19.8, 4.1, ok, , 
```

## Después

- Congelar los 20 primeros episodios verificados como **conjunto de regresión**:
  posiciones y poses de inicio fijas, contra las que se prueba cada política
  nueva antes de promoverla.
- Evaluar cada política con **al menos 20 pruebas reales** por configuración:
  con menos, el margen de error es de unos 20 puntos.
- Entrenar tras la etapa 1, no al final: así se aprende pronto qué falta.
