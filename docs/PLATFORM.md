# From game to platform — the Lex agent substrate

This repo started as a handful of capability-gated games and a governed robot.
It quietly became something more general: a **substrate for verifiable,
capability-bounded multi-agent activity** — and has since split into three
repos along that substrate/app boundary (see [#75](https://github.com/alpibrusl/lex-robot/issues/75)).
This note names the substrate, inventories the three layers, what the kernel
now delivers, and what's still missing. It is a map, not a spec — see the
linked code for the truth.

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

## The three layers (now three repos)

| repo | role |
|---|---|
| **[lex-robot](https://github.com/alpibrusl/lex-robot)** (here) | robot governance (grant gate + clamps · episode trails · `robot_task` verifier) + the shared A2A/bazaar/haggle mechanics + the platform kernel (identity, reputation, control plane) |
| **[lex-arena](https://github.com/alpibrusl/lex-arena)** | where games are played and hosted: the lobby, six capability-gated turn games, N-player Bazaar (ELO seasons), the BYO-key AI-agent arena, and the **Magentic Bazaar** (`gate.spend` + x402, LLM buyers/sellers, live WS contention, seller reputation) |
| **[lex-games](https://github.com/alpibrusl/lex-games)** | the lean, trusted verifier both of the above depend on to replay a trail and recompute a verdict — kept small (std + lex-trail only) so the hosted verify-worker image stays minimal |

lex-arena depends on lex-robot for the A2A core, the bazaar/haggle/seller-LLM
mechanics, and the Lex-native play host (`sidecar/sim_sidecar.lex`) — those
are also used by lex-robot's own robot-flavored A2A demos (`peer_meet`,
`ev_fleet`, `trading`, `triage`, `station`, `heist`, `logistics`), so keeping
them here (rather than duplicating, or fragmenting further) keeps one cohesive
module graph. See lex-robot#75 for the full extraction reasoning and what
moved where.

## The platform kernel — delivered

The kernel work identified below as "missing" is now built, in this repo:

1. **Durable `did:lex` identity + portable reputation** (`src/identity.lex`,
   `examples/agent_registry.lex` — [#80](https://github.com/alpibrusl/lex-robot/pull/80)).
   An agent is an ed25519 keypair; a reputation submission is **signed**, not
   claimed. The registry binds a DID to its key on first sight and refuses a
   later submission signed by a different key (impersonation earns nothing);
   verified-only accrual is preserved by reusing `lex-games`' replay. One
   identity now accumulates reputation **across apps** — proven live earning
   in both the robot domain and agent-ops under one profile.
2. **A control plane** (`src/control_plane.lex`,
   `examples/control_plane_demo.lex` — [#81](https://github.com/alpibrusl/lex-robot/pull/81)).
   An issuer signs a scoped, time-boxed, revocable Token to a subject `did:lex`;
   `verify()` re-derives whether it's currently authoritative (right subject,
   not revoked, not expired, valid signature) before the embedded Grant becomes
   usable — composing with, not replacing, every existing physical check.
3. **Standards-based signing.** Both of the above sign as real
   [lex-jose](https://github.com/alpibrusl/lex-jose) JWTs (EdDSA) rather than a
   hand-rolled detached signature — a reputation claim or a capability token is
   a genuine RFC 7519 token any JOSE-aware tool can decode, and verification
   re-checks the protected header's `alg` (algorithm-substitution defense) as
   part of the standard.

Together these deliver the roadmap's exit criterion: *an agent carries
identity + reputation between two different apps, and its authority is
issued/scoped/revoked through a control plane rather than hardcoded.*

## What's still missing

1. **Real settlement.** x402 is mocked (the real Solana `exact` leg exists in
   `lex-guard`; it isn't wired live) — lex-robot#24, #45.
2. **SD-JWT + AP2 mandate types.** `lex-jose` has the core JWT/JWS/JWK stack
   (HS256/HS512/EdDSA; ES256 pending a toolchain primitive) and this repo now
   signs on it, but selective-disclosure (`sd_jwt.lex`) and the AP2
   `CheckoutMandate`/`PaymentMandate` types are still on lex-jose's roadmap —
   lex-robot#23.
3. **Hosted verify-as-a-service + trust anchoring.** Verification runs locally;
   a platform would offer hosted replay + anchor trail roots so third parties
   trust a score without re-running it.
4. **SDK / onboarding.** A2A endpoints are documented, but there's no packaged
   "bring your agent in 5 minutes" SDK or agent template.
5. **Accounts / multi-tenancy** and **federation/discovery** (lex-slim is parked).

## Roadmap — game → platform

**Kernel: done** (see above). **Then lead with an app.** Candidates, in rough
build-cost order:

- **A — Verifiable agent eval / benchmark-as-a-service.** Submit a trail → a
  replay-verified score + ELO. Market: labs that need cheat-proof agent evals
  (most benchmarks are gameable; ours replays). Lowest new build — it *is* the
  arena, hosted. The robot-policy benchmark (lex-robot#65) and the XLeRobot
  safe-RL/eval loop are early instances of exactly this. **Recommended lead.**
- **B — Governed commerce, made real.** The bazaar with real x402 settlement,
  now backed by durable identity and a token-issuing control plane. The
  differentiated bet: governed agent payments is hot (x402/AP2/ACP) and
  unsolved on the trust side.
- **C — Auditable agent operations.** The governance + trail applied to
  enterprise agents doing real actions (spend, API calls, robot/finance ops) —
  audit-ready agent ops. Reuses robots + `lex-finance`/`lex-oms` + `lex-guard`.
- **D — lex-loom adoption.** The roadmap's recommended external wedge
  (lex-lang#708): loom standing on this kernel turns it from a self-audited
  sprint engine into a governed, independently-verifiable orchestrator whose
  agents earn portable reputation.

The unifying thesis: **agents earn portable, replay-verifiable reputation by
doing capability-bounded work — playing, trading, operating — and consumers
trust the scores because they can re-derive them.** Games proved it; the
bazaar made it transact; the kernel makes it durable and portable.
