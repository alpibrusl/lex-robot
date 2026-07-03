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

## 4. The robot task itself — `--agent robot`
The `--agent demo` above runs lex-os's scripted agent. `--agent robot` runs the
**robot task**: an in-guest agent proposes `move_to`/`grasp`/`run_policy` as
structured skills, the supervisor mediates each one's *arguments* against the
grant's `actuation` block (workspace box, force caps, skill allowlist), and on
approval the guest executes the skill against the gym sidecar over the egress
wall. Every observed outcome is recorded to the hash-chained audit log, which is
reconciled against the sidecar's lex-trail episode log.

### 4a. Simulated perimeter (no KVM, no GPU) — the wiring gate
```sh
./box/sim_e2e.sh
#   outcome: "GoalMet"   audit_verified: true
#   == reconcile ==  OK: 3 skill outcomes corroborate across both chains
```
This starts the dependency-free `sidecar/sim_sidecar.py`, runs `--agent robot`
against the simulated perimeter, and reconciles the two audit chains. NOT a
security boundary (`security_boundary: false`) — it proves the control + effect
+ audit + reconcile wiring. The out-of-grant variant proves the run-time block:
```sh
$LEXOS run --manifest $M --agent robot --guest-script robot-violation --simulated \
  --audit-out /tmp/robot-viol.json
#   command_denied: "x=0.9 outside workspace [0.1,0.5]"   ← blocked at run time, not check time
```

### 4b. Hardware-enforced box (Linux+KVM, root) — the real boundary
With `/dev/kvm` and root. **Stage the assets with the current guest baked into
the rootfs first** — `setup-assets.sh` rebuilds the static musl `lex-os-guest`
and loop-mounts it into `rootfs.ext4`, so re-run it whenever the guest changes
(otherwise the VM boots a stale agent that ignores the robot scripts):
```sh
cd ../lex-os && sudo bash demo/setup-assets.sh   # build + inject the current guest
cd ../lex-robot
sudo ./box/run_in_vm.sh                  # robot-demo (in-grant)
sudo ./box/run_in_vm.sh robot-violation  # out-of-grant move → Denied at the perimeter
```
Run the whole script with `sudo` (the jailer needs root). It clears stale
`/tmp/robot-{audit,trail}.json`, starts the dependency-free `sim_sidecar.py`
bound to `0.0.0.0:8900` (override with `SIDECAR_PY=gym_sidecar.py` on a
gym-capable host), runs the task in the microVM, and fails loudly if the audit
or trail wasn't freshly produced. Verifies (a) the in-grant run completes with
`audit_verified: true`; (b) a tight `max_commands` budget → `BudgetExhausted` +
supervisor kill/reprovision; (c) the out-of-grant move → run-time
`command_denied`, plus the kernel egress wall drops non-allowlisted hosts
(`lex-os/demo/wall2.sh`). The robot's effect is sealed inside the microVM behind
that wall.

> The policy **solve quality** — `run_policy` actually solving PushT at high
> reward — is tracked in issue #2 and demonstrated on a CUDA box. This run proves
> mediation + execution + audit + reconcile, not a learned solve.

## 5. XLeRobot in the box — the dual-envelope capsule, supervisor-enforced

`manifests/xlerobot.capsule.json` grants the XLeRobot skills and the mobile
base's floor area; since lex-os#49 the supervisor mediates all of them
(refuse-don't-downgrade: a granted skill with no mediation rule is refused).
With the XLeRobot stub sidecar running (`python3 sidecar/xlerobot_sidecar.py`):

```sh
M=manifests/xlerobot.capsule.json
G=../lex-os/target/debug/lex-os-guest
LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 $LEXOS run --manifest $M --agent robot   --guest-script xlerobot-demo --guest-bin $G --simulated --audit-out /tmp/xle-audit.json
#   outcome: "GoalMet"   audit_verified: true
#   move_base → move_arm → grasp_arm each command_requested → command_allowed → skill_outcome

LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 $LEXOS run --manifest $M --agent robot   --guest-script xlerobot-violation --guest-bin $G --simulated --audit-out /tmp/xle-viol.json
#   command_denied: "x=9 outside floor area [0,4]"   ← the capsule's base block, enforced
```

The same two scripts run in the real Firecracker box via `box/run_in_vm.sh`
on a KVM host (pass the script name, as with `robot-violation` above).
