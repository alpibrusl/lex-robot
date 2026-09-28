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
   │ bystander rule  ← code: a person within reach → no moving option at all
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
is regenerable. Each scene is asked **bare** (option descriptions only) and
**annotated** (plus precomputed feasibility notes). Raw rows:
`docs/judge_calibration/`. Measured 2026-09-28.

*Unsafe* = chose an option that moves the arm when the right answer was to stay
still. The grant still bounds *where* such a move goes, but not *whether*
moving was sensible.

| backend | options | accuracy | always-`hold` baseline | unsafe | ECE | p50 latency |
|---|---|---|---|---|---|---|
| Jev 1.13.0 | bare | 44% | 50% | 48 | 0.44 | 259 ms |
| Jev 1.13.0 | annotated | 63% | 50% | 36 | 0.15 | 264 ms |
| Laya (`convaiinnovations/laya` @ `55cf4c4`) | bare | 7.5% | 50% | 90 | 0.75 | 24 ms (M4 Max, MPS) |
| Laya | annotated | 8.3% | 50% | 90 | 0.58 | 30 ms |

Jev, annotated, by threshold:

| θ | acts on | wrong when acting | of which unsafe |
|---|---|---|---|
| 0.80 | 52% | 9 / 63 | 9 |
| 0.90 | 48% | 6 / 57 | 6 |
| **0.95** | **39%** | **1 / 47** | **1** |

**Findings**

1. **Laya does not do this task.** It answers `carry_to_bin` for all 120
   annotated scenes, and the same happens with prose states, JSON without the
   goal, and its `typed-decisions` checkpoint. It follows the option that best
   matches the goal's wording and ignores the facts. It *does* read facts that
   state the answer directly ("is a person near the arm?" → 0.86 vs 0.14), but
   anything that needs two facts combined fails. Its probabilities sit mostly
   between 0.6 and 0.9, so behind θ = 0.95 it never acts: in the demo the robot
   holds for all 12 steps and nothing moves. The gate catches a model that does
   not work.
2. **Jev needs the feasibility notes.** Without them it scores below always
   answering `hold`. With them its ≥ 0.95 band is 46/47 right. This is the
   jev-drone finding again: the state you write, not the model, sets the
   ceiling.
3. **Jev's confident mistakes are all contradictory scenes.** Every error at
   p ≥ 0.9 has `cup_seen: false` alongside a known cup location. Bystander
   scenes are handled correctly at that threshold. **No threshold reaches ≤ 1%
   wrong while acting** (0.95 gives 2.1%), so `recommend()` returns none, and
   the demo's θ = 0.95 is a demo setting, not a certified one.
4. **Deterministic facts should not be judged.** Anything code can decide — a
   bystander in reach, a target outside the grant, a cup not seen — is removed
   from the options before the model is asked. On this task, with exact facts,
   what remains is a state machine: **the oracle itself is the better planner.**
   A judge earns its place only where the input is genuinely fuzzy: a spoken
   goal, an ambiguous scene description, "is this the same object?". Those are
   the next things to measure, not skill sequencing from clean facts.

## Limits

- The facts are exact. On the robot they come from perception, so these numbers
  are a ceiling.
- 120 scenes and one task. Re-measure per task before trusting any θ.
- Laya's `confidence` field is an entropy measure; the harness gates on the
  probability of the chosen option for both backends, which is comparable.
