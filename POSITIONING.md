# Positioning & competitive landscape

> Snapshot as of 2026-06-14. The robot-governance space went from empty to
> actively contested in ~a year; this captures where lex-robot sits and what is
> actually defensible. Revisit quarterly — the "no longer a differentiator" list
> grows fast.

## One-liner

Everyone else is building the robot's **brain** (capability). We build its
**contract**: the open, *language-enforced* envelope that makes an untrusted
brain deployable — capability-bounded, evidence-gated, and tamper-evidently
audited, **above any policy** (LeRobot, Isaac/GR00T, or an LLM planner).

## The market, in layers

- **Policy / foundation models** — LeRobot (HF), NVIDIA Isaac/GR00T, Physical
  Intelligence (π0), Figure, Optimus, Skild, DeepMind RT-X. Racing on *capability*.
  We are orthogonal: we wrap the brain, we don't build it.
- **Classical functional safety** — safety PLCs, light curtains, ISO 10218 /
  ISO/TS 15066, e-stops. Certified, hardware-based. We are **not** this
  (DESIGN.md §8: software grant ≠ physical safety); we complement it.
- **Middleware / fleet** — ROS 2 + SROS2, Viam, Formant, Intrinsic, Foxglove.
  RBAC, command-execution audit, observability. Adjacent, different layer.
- **Embodied-agent runtime governance** — *our category*, and now crowded:
  - **AgentSpec** (ICSE 2026, SMU) — a rules DSL (triggers/predicates/enforcement)
    for LLM agents incl. embodied; eliminates 100% of hazardous embodied actions,
    ms overhead. Academic. Closest analog to the lex-os grant idea.
  - **"Governed Capability Evolution for Embodied Agents"** (arXiv 2604.08059) —
    capability admission, policy checks, execution watching, recovery, human
    override, audit logging. Strikingly close to lex-os. Academic.
  - **RoboSafe**, **SafeEmbodAI**, **"Harnessing Embodied Agents"** (2604.07833)
    — same theme, action-level enforcement above the policy. Academic.
- **Platform-owner runtime (the serious threat)** — NVIDIA **Halos** (end-to-end
  safety guardrails) + **OpenShell** ("runtime security boundary: isolating agent
  workloads, enforcing policy, keeping autonomous execution within guardrails"),
  GTC 2026. Our isolation+policy story — from the company that owns the silicon
  and GR00T. But NVIDIA-stack-locked.
- **Agentic-AI security standards** — AWS Agentic Scoping Matrix, regulatory
  audit-trail guidance standardizing hash-chained append-only provenance.

## What is still defensible (ranked by durability)

1. **Effect-typed, compile-time enforcement.** Others are a rules DSL (AgentSpec),
   config/RBAC (Viam), or a platform runtime (OpenShell). Lex makes capability a
   **typed property of the program** (static effect-wall) + runtime supervisor +
   microVM. A language is far harder to copy than a rules file — strongest moat.
2. **Evidence-gated completion** — "done" only when a real outcome confirms it
   (the OCPP/Verify pattern). Almost all governance work is *negative* (block bad
   actions); proving *task completion with positive evidence* is much less crowded.
3. **Open + portable + vendor-neutral** — runs above LeRobot, Isaac/GR00T, or an
   LLM. The wedge against OpenShell: be the Switzerland layer.

## No longer differentiators (commoditizing — do not lead with these)

- Hash-chained / tamper-evident audit provenance (being standardized).
- Basic action-blocking guardrails (academic DSLs will become open libraries).

## Honest threats / gaps

- **NVIDIA OpenShell/Halos** is existential: "good-enough" policy+isolation bundled
  with the dominant stack. Counter only by being clearly better, portable, *and*
  certifiable.
- We don't build the hard part (manipulation/policy); motion here is scripted / BC
  toy-level. Complement, not competitor, to the brain-builders.
- **Not certified** functional safety; the real guarantee needs the Firecracker
  microVM + firmware limits (Linux/KVM — issue #1). None of the academic work has
  certification either → a possible opening, but a heavy lift.
- Single-author prototype vs. funded platforms.

## Strategy

OSS is forced by the thesis (can't pitch "vendor-neutral" while closed). Sequence:

1. **Make it runnable by a stranger** — Docker image or one-line install so
   `examples/llm_planner_demo.lex` + `safe_rollout.lex` work out of the box. This
   is the real launch blocker (today they need the private `lex` toolchain).
2. **Open-source** lex-robot + the toolchain it needs to run.
3. **Lead with a written essay**, not an HN splash: "Judgment vs. Authority: an
   effect-typed governance layer for untrusted robot policies." Brutally honest
   (enforcement real; motion scripted; not certified; microVM pending) and
   explicitly mapped against AgentSpec (rules DSL) and OpenShell (vendor-locked).
4. **Then Show HN**, anchored on the LLM-planner demo ("the LLM proposes, the
   grant disposes"), linking the essay + runnable repo.

Tradeoff: HN is a one-shot megaphone — fire it only after 1–3 pre-empt the
obvious objections ("isn't this AgentSpec?", "software grant ≠ safety", "where's
the real robot?"). A paper on the effect-typed angle is a slower, optional track.

Lean the roadmap into the two least-crowded, hardest-to-copy axes: **effect-typing**
and **evidence-gated completion**, plus a credible **portability + certification**
path. Treat NVIDIA as interoperate-above, not compete-head-on.

## Sources

- Harnessing Embodied Agents: Runtime Governance — arXiv 2604.07833
- Governed Capability Evolution for Embodied Agents — arXiv 2604.08059
- AgentSpec (ICSE 2026) — arXiv 2503.18666
- RoboSafe: Safeguarding Embodied Agents via Executable Safety Logic
- SafeEmbodAI — arXiv 2409.01630
- NVIDIA GTC 2026 (Halos / OpenShell / NemoClaw) — blogs.nvidia.com/blog/gtc-2026-news
- Viam Fleet (access/audit/governance) — viam.com/product/fleet
- AWS Agentic AI Security Scoping Matrix
