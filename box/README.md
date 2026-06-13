# Running lex-robot under lex-os (the capability box)

Three layers of lex-os enforcement for the pick-place task, **all verified on
macOS** except the microVM (which needs Linux+KVM). Grant:
[`../manifests/pick_place.capsule.json`](../manifests/pick_place.capsule.json) —
`fs=read-write net=allowlist exec=none`, budgets, egress=localhost.

```
LEXOS=/path/to/lex-os/target/debug/lex-os
M=manifests/pick_place.capsule.json
```

## 1. Resolve — negotiate the grant against the host
```sh
$LEXOS resolve --manifest $M
#   grant: "fs=read-write net=allowlist exec=none"   net_egress: Allowlist
```

## 2. Static effect-wall — refuse programs that exceed the grant
```sh
$LEXOS check --grant $M box/agent_ok.lex
#   effects: ["fs_write","io","net"]   ok: true               ← admitted

$LEXOS check --grant $M box/agent_violation.lex
#   grant violation: effect `proc` needs exec ≥ `sandboxed`,
#   grant provides `none`                                       ← REFUSED before running
```

## 3. Runtime supervision — simulated perimeter (no KVM)
```sh
$LEXOS run --manifest $M --agent demo --audit-out /tmp/robot-audit.json
#   audit_verified: true        ← tamper-proof hash-chained log verifies
#   audit_entries: 13           ← provisioned → command_requested → budget_charged → …
#   outcome: "BudgetExhausted(\"money\")"   ← supervisor enforced budget + stopped
#   reprovisions: 1             ← reprovision-on-failure
```
Each audit entry chains `prev_hash → hash`; `audit_verified: true` means the
chain is intact. The supervisor mediates every command against the grant, tags
reversibility, charges the budget, and kills/reprovisions on breach.

## 4. Remaining: hardware-enforced box (Linux+KVM) — lex-robot#1
The `--agent demo` above runs lex-os's scripted agent, not the robot task. To
run the **robot task itself** inside an unbypassable Firecracker microVM as a
lex-os guest agent (issuing `move_to`/`grasp`/`run_policy` as mediated
commands), see issue #1 — that needs Linux+KVM and the guest protocol.
