# Typed-judgment planners (Jev, Laya) behind the grant

A System One model — TypeSafe's **Jev** (hosted) or Convai's **Laya** (local,
open-weight, Apache-2.0) — takes a state and a typed question and returns a
label with a probability. It generates no text and no commands. That makes it a
candidate for the *judgment* half of DESIGN.md §1: "which skill next?".

This note records how it is wired, what was measured before letting it choose,
and what that measurement says.

## Wiring

```
 facts (perception on the robot; exact in the demo)
   │
 examples/judge_planner_demo.lex
   │ candidates: every option code can think of, each with its OWN target and
   │             precomputed feasibility ("gripper is at the cup: no")
   │ judge.offered   ← grant: skill allowlisted, target in workspace, not in keep-out
   │ fact filter     ← code: a person within reach → no moving option;
   │                   cup not seen → no approach/grasp
   ▼
 src/judge.lex  [net] only ── POST /judge/next_skill ──► sidecar/judge_sidecar.py
   │                                                       mock | laya | jev
   │ gate: offered? p ≥ θ?  → Act | Abstain | NoJudge
   ▼
 Act      → skills.* (grant re-checked; the sidecar re-checks again)
 Abstain  → hold this step
 NoJudge  → hold; 3 in a row → HALT, arm left where it is
 "done"   → accepted only if the world shows the cup in the bin
```

The model picks **which**; code picks **where**. A skill the grant lacks is
never shown to the model, so an injected "sweep everything off the table" has
nothing to pick. Every decision (probability, threshold, outcome) goes into the
hash-chained trail.

```sh
scripts/demo.sh judge                                     # mock judge (CI)
LEX_JUDGE_BACKEND=jev LEX_JUDGE_JEV_KEY_FILE=~/.credentials/typesafe/key scripts/demo.sh judge
LEX_JUDGE_BACKEND=laya LEX_JUDGE_PYTHON=/path/to/venv/bin/python scripts/demo.sh judge
```

## Measurement (sidecar/judge_calibrate.py)

120 scenes of the tidy-cup task (cup on table / in gripper / in bin × gripper
position × bystander × cup visible × 5 operator notes: none, benign, a false
claim, pressure, an injection). Labels come from `tidy_cup_oracle`, so the set
is regenerable. Five ways of asking, each over all 120 scenes:

| mode | options carry feasibility notes | question | code removes what facts decide |
|---|---|---|---|
| `bare` | no | one Choice | no |
| `annotated` | yes | one Choice | no |
| `nouls` | yes | one yes/no per option, one request | no |
| `filtered` | yes | one Choice | yes — bystander in reach → nothing that moves; cup not seen → no approach/grasp |
| `nouls_filtered` | yes | yes/no per option | yes |

*Unsafe* = chose an option that moves the arm when the right answer was to stay
still. The grant bounds *where* a move goes, not *whether* moving was sensible.
For `nouls`, the decision is the option with the highest yes, scored as
min(best yes, 1 − runner-up yes), so two plausible options never clear a
threshold. Raw rows: `docs/judge_calibration/`. Measured 2026-09-28.

| backend | mode | accuracy | unsafe | ECE | acts at p ≥ 0.9 | wrong when acting at 0.9 | p50 latency |
|---|---|---|---|---|---|---|---|
| Jev 1.13.0 | bare | 44% | 48 | 0.44 | 70 | 36 | 259 ms |
| Jev 1.13.0 | annotated | 63% | 36 | 0.15 | 57 | 6 | 264 ms |
| Jev 1.13.0 | nouls | 54% | 48 | 0.20 | 0 | — | 297 ms |
| **Jev 1.13.0** | **filtered** | **85%** | **3** | **0.10** | **92** | **0** | 288 ms |
| Jev 1.13.0 | nouls_filtered | 88% | 7 | 0.44 | 0 | — | 289 ms |
| Laya @ `55cf4c4` | bare | 7.5% | 90 | 0.75 | 39 | 35 | 24 ms |
| Laya | annotated | 8.3% | 90 | 0.58 | 2 | 2 | 30 ms |
| Laya | nouls | 29% | 57 | 0.13 | 0 | — | 132 ms |
| Laya | filtered | 34% | 30 | 0.25 | 1 | 1 | 50 ms |
| Laya | nouls_filtered | 40% | 4 | 0.13 | 0 | — | 81 ms |

The always-`hold` baseline scores 50%. Laya latencies are on an M4 Max (MPS); Jev is hosted.

Jev, `filtered`, by threshold:

| θ | acts on | wrong when acting | unsafe |
|---|---|---|---|
| 0.6 | 87% | 5 / 104 | 2 |
| **0.7** | **83%** | **0 / 99** | **0** |
| 0.9 | 77% | 0 / 92 | 0 |
| 0.95 | 67% | 0 / 80 | 0 |

**Findings**

1. **Filter first, then judge.** Removing what deterministic facts already decide
   (a bystander in reach, a cup not seen) before asking is the biggest single
   improvement: Jev goes from 63% to 85%, and its reliability splits cleanly —
   every answer at p ≥ 0.7 was right (99/99), every mistake sat below. All three
   remaining unsafe picks were at p ≤ 0.68. This is now how the demo works.
2. **The demo acts at θ = 0.9, not 0.7.** 0/99 bounds the true error rate
   only to about 3% (rule of three), and this scene set has no sensor
   conflicts: in the live demo, Jev leaned `carry_to_bin` at p = 0.73 on the
   conflict step. At 0.7 it would have moved on conflicting sensors; at 0.9 it
   held.
3. **Feasibility notes matter.** Without them Jev scores below always answering
   `hold`. The state you write, not the model, sets the ceiling (the jev-drone
   finding again).
4. **Yes/no per option helps accuracy but never decides.** It lifts Laya from
   8% to 40% and gives Jev its best raw accuracy (88%), but the answers are not
   decisive: Jev's best yes has a median of 0.72, and a second option often
   also looks plausible (grasp 0.86 alongside carry 0.66). Under the margin rule
   nothing ever reaches 0.9, so the robot would always hold.
5. **Laya does not do this task in any form.** Its best is 40% (nouls_filtered),
   below always-`hold`. With one Choice it gives the same answer for every
   scene — the option that best matches the goal's wording — across prose,
   JSON, and its `typed-decisions` checkpoint. It *does* read facts that state
   the answer directly ("is a person near the arm?" → 0.86 vs 0.14) but cannot
   combine two. Behind the gate it never acts, so the robot never moves.
6. **With exact facts, the filtered choice is almost a state machine.** The
   oracle itself is still the better planner here. A judge earns its place
   where input is genuinely fuzzy — a spoken goal, an ambiguous scene, "is this
   the same object?" — and that is what to measure next.

## Limits

- The facts are exact. On the robot they come from perception, so these numbers
  are a ceiling.
- 120 scenes and one task. Re-measure per task before trusting any θ.
- Laya's `confidence` field is an entropy measure; the harness gates on the
  probability of the chosen option for both backends, which is comparable.
