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
