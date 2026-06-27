# From game to platform — the Lex agent substrate

This repo started as a handful of capability-gated games and a governed robot.
It has quietly become something more general: a **substrate for verifiable,
capability-bounded multi-agent activity**, with three apps already running on it.
This note names that substrate, inventories what exists, what's missing, and
where it goes next. It is a map, not a spec — see the linked code for the truth.

## The substrate — three primitives

Every app below is the same three primitives in a trench coat:

1. **Capability gating.** A signed token decides who may do what; the illegal
   call is refused *before* any logic runs — "anti-cheat by construction."
   `lex-guard`'s spend `gate` and `lex-robot`'s `grant` are two instances.
2. **Hash-chained trails.** Every accepted action is appended to a content-
   addressed `lex-trail`; tamper with any field and its id stops recomputing.
3. **Replay-verification + ranking.** The outcome is *recomputed from the trail*
   by the rules — never trusted from the client — and ranked by the recomputed
   result. `lex-games` does this for ELO (skill), revenue (commerce), and score
   (robots): **"a submission is a trail, not a score."**

Together they turn any multi-agent activity into something **provable**: you can
hand a third party a trail and a budget/grant, and they can re-derive exactly
what happened and how well, without trusting you.

## The apps (three, today)

| app | what it governs | key pieces |
|-----|-----------------|------------|
| **Games** | skill, fair play | 6 capability-gated turn games · N-player multi-model arena · ELO seasons (`lex-games` nbazaar / nbazaar_season; `examples/nplayer_bazaar*`) |
| **Robots** | physical control | grant gate + clamps · episode trails · `robot_task` verifier (lex-os robot-in-box; `examples/task.lex`, `policy_eval`) |
| **Commerce** | money | the **Magentic Bazaar**: `gate.spend` + x402 · LLM buyers/sellers · concurrent + live WS contention · seller reputation · live lobby boards (`examples/bazaar_*`) |

The **Magentic Bazaar** is the most developed second app — eight increments from
a single governed transaction to a live WebSocket market of remote agents with a
self-refreshing reputation board. See [the Magentic Bazaar section of the
README](../README.md) and `examples/bazaar_*`.

## What's missing — the platform kernel

To go from "three demos on a substrate" to "a platform others build on":

1. **Durable agent identity + portable reputation.** Reputation is recomputed
   per-manifest today, not *owned* by an agent that carries it across sessions
   and apps. There is no agent registry.
2. **A control plane.** Capability/budget tokens and policies are hardcoded in
   examples. There's no UI/API to issue, scope, revoke them, or to review trails.
3. **Real settlement.** x402 is mocked (the real Solana `exact` leg exists in
   `lex-guard`; it isn't wired live).
4. **Hosted verify-as-a-service + trust anchoring.** Verification runs locally;
   a platform would offer hosted replay + anchor trail roots so third parties
   trust a score without re-running it.
5. **SDK / onboarding.** A2A endpoints are documented, but there's no packaged
   "bring your agent in 5 minutes" SDK or agent template.
6. **Accounts / multi-tenancy** and **federation/discovery** (lex-slim is parked).

## Roadmap — game → platform

**Kernel first** (cross-cutting, unblocks every app): agent identity + persistent
verifiable reputation + a minimal control plane (issue/scope/revoke tokens,
browse trails).

**Then lead with an app.** Candidates, in rough build-cost order:

- **A — Verifiable agent eval / benchmark-as-a-service.** Submit a trail → a
  replay-verified score + ELO. Market: labs that need cheat-proof agent evals
  (most benchmarks are gameable; ours replays). Lowest new build — it *is* the
  arena, hosted. **Recommended lead.**
- **B — Governed commerce, made real.** The bazaar with real x402 settlement,
  agent identity, and a token-issuing control plane. The differentiated bet:
  governed agent payments is hot (x402/AP2/ACP) and unsolved on the trust side.
- **C — Auditable agent operations.** The governance + trail applied to
  enterprise agents doing real actions (spend, API calls, robot/finance ops) —
  audit-ready agent ops. Reuses robots + `lex-finance`/`lex-oms` + `lex-guard`.
- **D — Agent reputation / trust network.** The kernel itself, productized: a
  portable, recomputable reputation that travels across apps — a "credit score
  for agents."

The unifying thesis: **agents earn portable, replay-verifiable reputation by
doing capability-bounded work — playing, trading, operating — and consumers
trust the scores because they can re-derive them.** Games proved it; the bazaar
made it transact; the platform makes it durable.
