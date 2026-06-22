# Robot-in-box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the lex-robot pick-place task as a supervised lex-os Firecracker guest, where an in-guest agent proposes robot skills, the supervisor does grant-aware mediation + budget + hash-chained audit, and on approval the guest executes the skill against the host gym sidecar through the kernel egress wall.

**Architecture:** Two control planes. Control plane = vsock (guest agent ↔ host supervisor), carrying a per-skill handshake (view → RunSkill → Decision → SkillOutcome). Effect plane = egress-walled TCP (guest → host sidecar at `10.0.2.2:<port>` over HTTP/JSON, like the existing Ollama path). The supervisor gains a `mediate_skill` chokepoint that checks skill arguments against a new optional `actuation` block in the manifest; on `Allowed` it calls a new `Agent::execute_skill` hook that, for the vsock agent, tells the guest to run the effect and returns the observed outcome.

**Tech Stack:** Rust (lex-os crates: manifest, proto, supervisor, guest, CLI), Python 3.10+ (gym sidecar, already HTTP/JSON), Lex (lex-trail content-addressed event chain), Firecracker + KVM (host perimeter).

**Spec:** `docs/superpowers/specs/2026-06-16-robot-in-box-design.md`

**Repos (both are siblings under `/home/alpibru/workspace/alpibrusl/`):**
- `lex-os` — perimeter + supervisor + guest + proto (Rust workspace)
- `lex-robot` — manifest, sidecar, box scripts (this repo)
- `lex-trail` — Lex content-addressed event log (reference for the episode-log format)

**Environment note (this host):** `git` here needs `GIT_CONFIG_NOSYSTEM=1` and `GIT_EXEC_PATH=/usr/lib/git-core` exported, and `cargo`/`gh` work with those set. Prefix git commands accordingly. lex-os builds with `cargo build -p lex-os --features firecracker` (verified). `/dev/kvm` is present; the real boxed run additionally needs root/jailer (Phase 9).

---

## File Structure

**lex-os (Rust):**
- `crates/lex-os-manifest/src/actuation.rs` — NEW: `Actuation`, `ActuatorArm`, `ActuatorGripper`, `SkillReversibility` types + arg-bounds checks. One responsibility: the robot half of the grant.
- `crates/lex-os-manifest/src/lib.rs` — MODIFY: add optional `actuation: Option<Actuation>` field to `Manifest`, wire into `canonical_json`, re-export.
- `crates/lex-os-proto/src/msg.rs` — MODIFY: add `AgentActionMsg::RunSkill`, `SkillDecisionMsg`, `SkillOutcomeMsg`.
- `crates/lex-os-proto/src/transport.rs` — MODIFY: add `send_decision`/`recv_outcome` (Transport) and `recv_decision`/`send_outcome` (GuestTransport), implemented for Simulated + Stream pairs.
- `crates/lex-os-supervisor/src/skill.rs` — NEW: `SkillRequest`, `SkillOutcome`, and `mediate_skill` (grant-aware arg-checking against `Actuation`). One responsibility: skill-level mediation.
- `crates/lex-os-supervisor/src/lib.rs` — MODIFY: `AgentAction::RunSkill`, `Agent::execute_skill` hook, run-loop arm, record outcome.
- `crates/lex-os-audit/src/lib.rs` — MODIFY: add `Event::SkillOutcome { command, outcome, observation }`.
- `crates/lex-os-supervisor/src/vsock_agent.rs` — MODIFY: override `execute_skill` (send decision over transport, recv outcome).
- `crates/lex-os-guest/src/main.rs` — MODIFY: `robot-demo`/`robot-violation` script modes; on Allowed, call the sidecar via `ureq`.
- `crates/lex-os/src/main.rs` — MODIFY: `AgentBackend::Robot`, dispatch, `--sidecar-host`/`--sidecar-port` flags.

**lex-robot:**
- `sidecar/gym_sidecar.py` — MODIFY: bind to a guest-reachable host; emit a lex-trail-format episode log.
- `sidecar/trail.py` — NEW: content-addressed lex-trail event emitter (Python mirror of `lex-trail/src/event.lex`).
- `manifests/pick_place.capsule.json` — MODIFY: add `actuation` block; reconcile `egress` to the guest-visible sidecar address.
- `scripts/reconcile_audit.py` — NEW: assert the lex-os audit log and the sidecar episode log corroborate.
- `box/run_in_vm.sh` — NEW: the boxed-run runbook script.
- `box/README.md` — MODIFY: replace §4 "remaining" with the real run.

---

## Phase 0: Prerequisites & build harness (ops, no code)

### Task 0: Confirm the toolchain and assets

**Files:** none (verification only).

- [ ] **Step 1: Confirm KVM + virtualization**

```bash
test -e /dev/kvm && echo "kvm ok"
grep -m1 -oE 'vmx|svm' /proc/cpuinfo
```
Expected: `kvm ok` and `vmx` (already confirmed on this host).

- [ ] **Step 2: Confirm lex-os builds with the firecracker feature**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo build -p lex-os --features firecracker
```
Expected: `Finished` with no errors (verified once already).

- [ ] **Step 3: Add the musl target for the in-VM guest build**

```bash
rustup target add x86_64-unknown-linux-musl
```
Expected: target installed (or "up to date").

- [ ] **Step 4: Install sidecar deps on the host**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
python3 -m pip install -r sidecar/requirements.txt 'pymunk<7'
```
Expected: gymnasium, gym-pusht, pillow, numpy installed. (lerobot/torch only needed for `run_policy` quality, which is Issue #2 on the CUDA box — not required for this milestone.)

- [ ] **Step 5: Smoke the sidecar over HTTP (proves the effect-plane contract)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
python3 sidecar/gym_sidecar.py &
sleep 8
curl -s localhost:8900/health
curl -s -X POST localhost:8900/skill/read_joints -d '{}'
curl -s -X POST localhost:8900/skill/move_to -d '{"x":0.4,"y":0.4}'
kill %1
```
Expected: `{"ok": true, ...}`, a joints JSON, and a `move_to` outcome JSON. This confirms the sidecar already speaks the HTTP/JSON the guest will use.

No commit (verification only).

---

## Phase 1: Manifest `actuation` block (lex-os-manifest)

### Task 1: Actuation types + arg-bounds checks

**Files:**
- Create: `lex-os/crates/lex-os-manifest/src/actuation.rs`
- Test: same file (`#[cfg(test)]`).

- [ ] **Step 1: Write the failing test**

Create `lex-os/crates/lex-os-manifest/src/actuation.rs`:

```rust
//! The robot half of the grant: which skills are allowed and the
//! kinematic/force bounds each actuating skill is held to. Optional on a
//! `Manifest` — absent means lex-os behaves exactly as before (generic
//! agent box). Present means the supervisor's `mediate_skill` checks every
//! skill argument against these bounds before the effect runs.

use serde::{Deserialize, Serialize};

/// A closed interval `[min, max]` in metres for one workspace axis.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Range {
    pub min: f64,
    pub max: f64,
}

impl Range {
    pub fn contains(&self, v: f64) -> bool {
        v >= self.min && v <= self.max
    }
}

/// Arm actuator bounds. `workspace_m` is `[x, y, z]` ranges in metres.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ActuatorArm {
    pub workspace_m: [Range; 3],
    pub max_velocity_mps: f64,
    pub max_force_n: f64,
}

/// Gripper actuator bounds.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ActuatorGripper {
    pub max_grip_force_n: f64,
}

/// The actuation grant: allowed skills + per-actuator caps. Reversibility
/// per skill is carried as `(skill, class)` pairs so the supervisor can
/// reuse the existing `Reversibility` gate.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Actuation {
    pub skills: Vec<String>,
    pub arm: ActuatorArm,
    pub gripper: ActuatorGripper,
}

impl Actuation {
    /// Is `skill` named in the grant's allowlist?
    pub fn allows(&self, skill: &str) -> bool {
        self.skills.iter().any(|s| s == skill)
    }

    /// Check a `move_to` target `(x, y, z)` against the workspace box.
    /// Returns the offending axis name on failure.
    pub fn check_move_to(&self, x: f64, y: f64, z: f64) -> Result<(), String> {
        let axes = [("x", x, self.arm.workspace_m[0]),
                    ("y", y, self.arm.workspace_m[1]),
                    ("z", z, self.arm.workspace_m[2])];
        for (name, v, range) in axes {
            if !range.contains(v) {
                return Err(format!(
                    "{name}={v} outside workspace [{},{}]", range.min, range.max
                ));
            }
        }
        Ok(())
    }

    /// Check a grasp force against the gripper cap.
    pub fn check_grasp(&self, force_n: f64) -> Result<(), String> {
        if force_n > self.gripper.max_grip_force_n {
            return Err(format!(
                "force {force_n}N exceeds max_grip_force_n {}",
                self.gripper.max_grip_force_n
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Actuation {
        Actuation {
            skills: vec!["move_to".into(), "grasp".into(), "run_policy".into()],
            arm: ActuatorArm {
                workspace_m: [Range { min: 0.1, max: 0.5 },
                              Range { min: -0.3, max: 0.3 },
                              Range { min: 0.0, max: 0.4 }],
                max_velocity_mps: 0.25,
                max_force_n: 15.0,
            },
            gripper: ActuatorGripper { max_grip_force_n: 20.0 },
        }
    }

    #[test]
    fn allows_only_listed_skills() {
        let a = sample();
        assert!(a.allows("move_to"));
        assert!(!a.allows("connect_charger"));
    }

    #[test]
    fn move_to_inside_workspace_ok() {
        assert!(sample().check_move_to(0.3, 0.0, 0.2).is_ok());
    }

    #[test]
    fn move_to_outside_workspace_denied() {
        let err = sample().check_move_to(0.9, 0.0, 0.2).unwrap_err();
        assert!(err.contains("x=0.9"));
    }

    #[test]
    fn grasp_over_force_denied() {
        assert!(sample().check_grasp(50.0).is_err());
        assert!(sample().check_grasp(10.0).is_ok());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails to compile (module not wired)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-manifest actuation 2>&1 | tail -5
```
Expected: FAIL — `actuation` module not declared in `lib.rs`.

- [ ] **Step 3: Wire the module + re-export in `lib.rs`**

In `lex-os/crates/lex-os-manifest/src/lib.rs`, after the `pub use lex_types::trust::...` line (line 15), add:

```rust
mod actuation;
pub use actuation::{Actuation, ActuatorArm, ActuatorGripper, Range};
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-manifest actuation 2>&1 | tail -8
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git checkout -b robot-in-box 2>/dev/null || git checkout robot-in-box
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-manifest/src/actuation.rs crates/lex-os-manifest/src/lib.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(manifest): add optional actuation block with arg-bounds checks"
```

### Task 2: Add `actuation` to `Manifest` and its canonical JSON

**Files:**
- Modify: `lex-os/crates/lex-os-manifest/src/lib.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` mod in `lex-os/crates/lex-os-manifest/src/lib.rs`:

```rust
    #[test]
    fn actuation_is_optional_and_roundtrips() {
        // A manifest with no actuation behaves as before.
        let plain = analyze_manifest();
        assert!(plain.actuation.is_none());
        let back = Manifest::from_json(&plain.to_json().unwrap()).unwrap();
        assert_eq!(plain.content_id(), back.content_id());

        // Adding actuation changes the content address and survives a roundtrip.
        let with_act = Manifest {
            actuation: Some(Actuation {
                skills: vec!["move_to".into()],
                arm: ActuatorArm {
                    workspace_m: [Range { min: 0.1, max: 0.5 },
                                  Range { min: -0.3, max: 0.3 },
                                  Range { min: 0.0, max: 0.4 }],
                    max_velocity_mps: 0.25,
                    max_force_n: 15.0,
                },
                gripper: ActuatorGripper { max_grip_force_n: 20.0 },
            }),
            ..plain.clone()
        };
        assert_ne!(plain.content_id(), with_act.content_id());
        let back2 = Manifest::from_json(&with_act.to_json().unwrap()).unwrap();
        assert_eq!(back2.actuation, with_act.actuation);
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-manifest actuation_is_optional 2>&1 | tail -8
```
Expected: FAIL — no field `actuation` on `Manifest`.

- [ ] **Step 3: Add the field, the constructor default, and canonical JSON**

In `lex-os/crates/lex-os-manifest/src/lib.rs`:

a) Add the field to the `Manifest` struct (after `egress`, around line 161):

```rust
    /// The robot half of the grant. `None` for ordinary agent boxes; when
    /// present, the supervisor mediates each skill's arguments against it.
    #[serde(default)]
    pub actuation: Option<Actuation>,
```

b) In `Manifest::new` (around line 201-210), add `actuation: None,` to the returned struct literal.

c) In `narrow_to` (around line 320-328), add `actuation: self.actuation.clone(),` to the returned `Manifest`.

d) In `canonical_json` (around line 349-365), add an `actuation` key to the `serde_json::json!` value so it affects the content address:

```rust
            "actuation": self.actuation,
```
(serde serializes `Option<Actuation>` as `null` when absent, preserving the old content address for actuation-free manifests because `null` is the back-compat default — verified by the test's `plain.content_id() == back.content_id()`.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-manifest 2>&1 | tail -8
```
Expected: all manifest tests pass (including the existing `old_manifests_without_egress_still_deserialize`, which still loads because `actuation` is `#[serde(default)]`).

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-manifest/src/lib.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(manifest): carry optional actuation in Manifest + content id"
```

---

## Phase 2: Proto skill messages (lex-os-proto)

### Task 3: Skill action + decision + outcome wire messages

**Files:**
- Modify: `lex-os/crates/lex-os-proto/src/msg.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` mod in `lex-os/crates/lex-os-proto/src/msg.rs`:

```rust
    #[test]
    fn run_skill_round_trips() {
        let a = AgentActionMsg::RunSkill {
            skill: "move_to".into(),
            args: serde_json::json!({"x": 0.3, "y": 0.0, "z": 0.2}),
        };
        let json = serde_json::to_string(&a).unwrap();
        assert!(json.contains("\"action\":\"run_skill\""));
        let back: AgentActionMsg = serde_json::from_str(&json).unwrap();
        assert!(matches!(back, AgentActionMsg::RunSkill { skill, .. } if skill == "move_to"));
    }

    #[test]
    fn decision_and_outcome_round_trip() {
        let d = SkillDecisionMsg { allowed: false, reason: Some("out of workspace".into()) };
        let back: SkillDecisionMsg = serde_json::from_str(&serde_json::to_string(&d).unwrap()).unwrap();
        assert!(!back.allowed);

        let o = SkillOutcomeMsg { outcome: "reached".into(), observation: "{\"coverage\":0.9}".into() };
        let back2: SkillOutcomeMsg = serde_json::from_str(&serde_json::to_string(&o).unwrap()).unwrap();
        assert_eq!(back2.outcome, "reached");
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-proto run_skill 2>&1 | tail -6
```
Expected: FAIL — `RunSkill`/`SkillDecisionMsg`/`SkillOutcomeMsg` not found.

- [ ] **Step 3: Add the variants + structs**

In `lex-os/crates/lex-os-proto/src/msg.rs`:

a) Add a variant to `AgentActionMsg` (inside the enum, after `Run`):

```rust
    /// Request a mediated *robot skill* with structured arguments. The
    /// supervisor mediates the args against the manifest's actuation block,
    /// replies with a `SkillDecisionMsg`, and (if allowed) awaits a
    /// `SkillOutcomeMsg` after the guest executes the effect.
    RunSkill { skill: String, args: serde_json::Value },
```

b) Add the two new message structs after the `AgentActionMsg` enum:

```rust
/// Host → Guest. The supervisor's decision on a `RunSkill`, sent before any
/// effect runs. On `allowed: true` the guest executes the skill against the
/// sidecar and replies with a `SkillOutcomeMsg`; on `false` it loops to the
/// next view.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillDecisionMsg {
    pub allowed: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

/// Guest → Host. The observed result of executing an approved skill against
/// the sidecar. `observation` is the raw sidecar JSON (for the audit log).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillOutcomeMsg {
    pub outcome: String,
    pub observation: String,
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-proto 2>&1 | tail -8
```
Expected: all proto tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-proto/src/msg.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(proto): RunSkill action + SkillDecision/SkillOutcome messages"
```

### Task 4: Transport methods for the skill handshake

**Files:**
- Modify: `lex-os/crates/lex-os-proto/src/transport.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` mod in `lex-os/crates/lex-os-proto/src/transport.rs`:

```rust
    #[test]
    fn simulated_pair_skill_handshake() {
        use crate::msg::{SkillDecisionMsg, SkillOutcomeMsg};
        let (mut host, mut guest) = simulated_pair();

        // Host decides, guest receives.
        host.send_decision(&SkillDecisionMsg { allowed: true, reason: None }).unwrap();
        let d = guest.recv_decision().unwrap();
        assert!(d.allowed);

        // Guest reports outcome, host receives.
        guest.send_outcome(&SkillOutcomeMsg {
            outcome: "reached".into(), observation: "{}".into(),
        }).unwrap();
        let o = host.recv_outcome().unwrap();
        assert_eq!(o.outcome, "reached");
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-proto skill_handshake 2>&1 | tail -6
```
Expected: FAIL — `send_decision`/`recv_decision`/`send_outcome`/`recv_outcome` not found.

- [ ] **Step 3: Add the trait methods + implementations**

In `lex-os/crates/lex-os-proto/src/transport.rs`:

a) Add to the `Transport` trait (after `recv_action`, before `reconnect`):

```rust
    /// Send the supervisor's per-skill decision to the guest (one JSON line).
    fn send_decision(&mut self, decision: &crate::msg::SkillDecisionMsg) -> anyhow::Result<()>;
    /// Block until the guest reports a skill outcome (one JSON line).
    fn recv_outcome(&mut self) -> anyhow::Result<crate::msg::SkillOutcomeMsg>;
```

b) Add to the `GuestTransport` trait:

```rust
    fn recv_decision(&mut self) -> anyhow::Result<crate::msg::SkillDecisionMsg>;
    fn send_outcome(&mut self, outcome: &crate::msg::SkillOutcomeMsg) -> anyhow::Result<()>;
```

c) Implement for `SimulatedTransport` (reuse its `tx`/`rx` channels, same pattern as `send_view`/`recv_action`):

```rust
    fn send_decision(&mut self, decision: &crate::msg::SkillDecisionMsg) -> anyhow::Result<()> {
        let line = serde_json::to_string(decision).context("serialise decision")?;
        self.tx.send(line).context("send decision")?;
        Ok(())
    }
    fn recv_outcome(&mut self) -> anyhow::Result<crate::msg::SkillOutcomeMsg> {
        let line = self.rx.recv().context("recv outcome")?;
        serde_json::from_str(&line).context("deserialise outcome")
    }
```

d) Implement for `SimulatedGuestTransport`:

```rust
    fn recv_decision(&mut self) -> anyhow::Result<crate::msg::SkillDecisionMsg> {
        let line = self.rx.recv().context("recv decision")?;
        serde_json::from_str(&line).context("deserialise decision")
    }
    fn send_outcome(&mut self, outcome: &crate::msg::SkillOutcomeMsg) -> anyhow::Result<()> {
        let line = serde_json::to_string(outcome).context("serialise outcome")?;
        self.tx.send(line).context("send outcome")?;
        Ok(())
    }
```

e) Implement for `StreamTransport<R, W>` (newline-framed, same as `send_view`/`recv_action`):

```rust
    fn send_decision(&mut self, decision: &crate::msg::SkillDecisionMsg) -> anyhow::Result<()> {
        let mut line = serde_json::to_string(decision).context("serialise decision")?;
        line.push('\n');
        self.writer.write_all(line.as_bytes()).context("write decision")?;
        self.writer.flush().context("flush")?;
        Ok(())
    }
    fn recv_outcome(&mut self) -> anyhow::Result<crate::msg::SkillOutcomeMsg> {
        let mut line = String::new();
        self.reader.read_line(&mut line).context("read outcome")?;
        serde_json::from_str(line.trim()).context("deserialise outcome")
    }
```

f) Implement for `StreamGuestTransport<R, W>`:

```rust
    fn recv_decision(&mut self) -> anyhow::Result<crate::msg::SkillDecisionMsg> {
        let mut line = String::new();
        self.reader.read_line(&mut line).context("read decision")?;
        serde_json::from_str(line.trim()).context("deserialise decision")
    }
    fn send_outcome(&mut self, outcome: &crate::msg::SkillOutcomeMsg) -> anyhow::Result<()> {
        let mut line = serde_json::to_string(outcome).context("serialise outcome")?;
        line.push('\n');
        self.writer.write_all(line.as_bytes()).context("write outcome")?;
        self.writer.flush().context("flush")?;
        Ok(())
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-proto 2>&1 | tail -8
```
Expected: all proto tests pass (incl. the existing vsock-feature-gated build; the new methods are non-feature-gated so the vsock `StreamGuestTransport` inherits them).

- [ ] **Step 5: Verify the vsock-feature build still compiles**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo check -p lex-os-proto --features vsock 2>&1 | tail -4
```
Expected: `Finished` (the vsock transport is a `StreamGuestTransport`, so it gets the new methods for free).

- [ ] **Step 6: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-proto/src/transport.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(proto): transport methods for the per-skill handshake"
```

---

## Phase 3: Supervisor skill mediation (lex-os-supervisor)

### Task 5: Audit event for skill outcomes

**Files:**
- Modify: `lex-os/crates/lex-os-audit/src/lib.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` mod in `lex-os/crates/lex-os-audit/src/lib.rs`:

```rust
    #[test]
    fn skill_outcome_event_chains_and_verifies() {
        let mut log = AuditLog::new();
        log.append(Event::CommandAllowed { command: "move_to".into() });
        log.append(Event::SkillOutcome {
            command: "move_to".into(),
            outcome: "reached".into(),
            observation: "{\"coverage_reward\":0.9}".into(),
        });
        assert!(log.verify().is_ok());
        assert!(log.to_ndjson().unwrap().contains("skill_outcome"));
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-audit skill_outcome 2>&1 | tail -6
```
Expected: FAIL — no variant `SkillOutcome`.

- [ ] **Step 3: Add the variant**

In `lex-os/crates/lex-os-audit/src/lib.rs`, add to the `Event` enum (after `CommandAllowed`, around line 37):

```rust
    /// The observed result of an approved skill executed in the guest.
    /// Recorded after the effect so the audit log carries outcomes, not
    /// just decisions.
    SkillOutcome {
        command: String,
        outcome: String,
        observation: String,
    },
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-audit 2>&1 | tail -6
```
Expected: all audit tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-audit/src/lib.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(audit): SkillOutcome event"
```

### Task 6: `mediate_skill` — grant-aware argument mediation

**Files:**
- Create: `lex-os/crates/lex-os-supervisor/src/skill.rs`
- Test: same file.

- [ ] **Step 1: Write the failing test**

Create `lex-os/crates/lex-os-supervisor/src/skill.rs`:

```rust
//! Skill-level mediation: the robot analogue of `mediate`. Where `mediate`
//! checks a command *name* against a trust dimension/level, `mediate_skill`
//! checks a skill's *arguments* against the manifest's `Actuation` bounds —
//! the run-time block that catches an out-of-workspace `move_to` or an
//! over-force `grasp` before the effect leaves the box.

use lex_os_manifest::Actuation;
use serde_json::Value;

/// The supervisor's verdict on a skill request, mapped later onto the
/// existing `Decision` type by the run loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SkillVerdict {
    Allowed,
    Denied(String),
}

/// Mediate one skill request against the actuation grant. Pure: no audit,
/// no budget (the run loop owns those, reusing the existing gates).
pub fn mediate_skill(actuation: &Actuation, skill: &str, args: &Value) -> SkillVerdict {
    if !actuation.allows(skill) {
        return SkillVerdict::Denied(format!("skill `{skill}` not in the grant"));
    }
    let num = |k: &str, default: f64| args.get(k).and_then(Value::as_f64).unwrap_or(default);
    match skill {
        "move_to" => {
            // Sidecar treats (x,y) as normalised [0,1]; z defaults to mid-range.
            // We check the raw requested values against the workspace box.
            match actuation.check_move_to(num("x", 0.5), num("y", 0.5), num("z", 0.0)) {
                Ok(()) => SkillVerdict::Allowed,
                Err(e) => SkillVerdict::Denied(e),
            }
        }
        "grasp" => match actuation.check_grasp(num("force", 0.0)) {
            Ok(()) => SkillVerdict::Allowed,
            Err(e) => SkillVerdict::Denied(e),
        },
        // run_policy and sense-only skills carry no kinematic args to bound
        // here; the skill-allowlist check above is their gate.
        _ => SkillVerdict::Allowed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lex_os_manifest::{ActuatorArm, ActuatorGripper, Range};
    use serde_json::json;

    fn act() -> Actuation {
        Actuation {
            skills: vec!["move_to".into(), "grasp".into(), "run_policy".into()],
            arm: ActuatorArm {
                workspace_m: [Range { min: 0.1, max: 0.5 },
                              Range { min: -0.3, max: 0.3 },
                              Range { min: 0.0, max: 0.4 }],
                max_velocity_mps: 0.25,
                max_force_n: 15.0,
            },
            gripper: ActuatorGripper { max_grip_force_n: 20.0 },
        }
    }

    #[test]
    fn ungranted_skill_denied() {
        assert!(matches!(
            mediate_skill(&act(), "connect_charger", &json!({})),
            SkillVerdict::Denied(_)
        ));
    }

    #[test]
    fn in_workspace_move_allowed() {
        assert_eq!(mediate_skill(&act(), "move_to", &json!({"x":0.3,"y":0.0,"z":0.2})), SkillVerdict::Allowed);
    }

    #[test]
    fn out_of_workspace_move_denied() {
        assert!(matches!(
            mediate_skill(&act(), "move_to", &json!({"x":0.9,"y":0.0})),
            SkillVerdict::Denied(_)
        ));
    }

    #[test]
    fn over_force_grasp_denied() {
        assert!(matches!(
            mediate_skill(&act(), "grasp", &json!({"force":50.0})),
            SkillVerdict::Denied(_)
        ));
    }

    #[test]
    fn run_policy_passes_allowlist_gate() {
        assert_eq!(mediate_skill(&act(), "run_policy", &json!({"name":"x"})), SkillVerdict::Allowed);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor skill:: 2>&1 | tail -5
```
Expected: FAIL — `skill` module not declared.

- [ ] **Step 3: Wire the module**

In `lex-os/crates/lex-os-supervisor/src/lib.rs`, add near the other `mod` lines (around line 21-23):

```rust
mod skill;
```
and re-export after the other `pub use` lines (around line 25-27):

```rust
pub use skill::{mediate_skill, SkillVerdict};
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor skill:: 2>&1 | tail -8
```
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-supervisor/src/skill.rs crates/lex-os-supervisor/src/lib.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(supervisor): mediate_skill — grant-aware arg mediation"
```

### Task 7: `AgentAction::RunSkill`, the `execute_skill` hook, and run-loop integration

**Files:**
- Modify: `lex-os/crates/lex-os-supervisor/src/lib.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` mod in `lex-os/crates/lex-os-supervisor/src/lib.rs`. This uses a scripted in-process agent that returns one in-grant skill then one out-of-grant skill, asserting the audit log records an allowed `SkillOutcome` and a denial. Place a helper `Actuation` and agent near the existing test helpers:

```rust
    fn actuation_grant() -> lex_os_manifest::Actuation {
        use lex_os_manifest::{Actuation, ActuatorArm, ActuatorGripper, Range};
        Actuation {
            skills: vec!["move_to".into()],
            arm: ActuatorArm {
                workspace_m: [Range { min: 0.1, max: 0.5 },
                              Range { min: -0.3, max: 0.3 },
                              Range { min: 0.0, max: 0.4 }],
                max_velocity_mps: 0.25,
                max_force_n: 15.0,
            },
            gripper: ActuatorGripper { max_grip_force_n: 20.0 },
        }
    }

    /// Scripted agent: emit an in-grant move, then an out-of-grant move, then done.
    /// `execute_skill` returns a canned outcome for the allowed case.
    struct SkillScript { step: usize }
    impl Agent for SkillScript {
        fn next_action(&mut self, _v: &AgentView) -> AgentAction {
            self.step += 1;
            match self.step {
                1 => AgentAction::RunSkill { skill: "move_to".into(), args: serde_json::json!({"x":0.3,"y":0.0,"z":0.2}) },
                2 => AgentAction::RunSkill { skill: "move_to".into(), args: serde_json::json!({"x":0.9,"y":0.0}) },
                _ => AgentAction::Done,
            }
        }
        fn execute_skill(&mut self, _decision: &Decision) -> Option<crate::SkillOutcome> {
            Some(crate::SkillOutcome { outcome: "reached".into(), observation: "{}".into() })
        }
    }

    #[test]
    fn skill_mediation_allows_then_denies_and_audits_outcome() {
        let mut manifest = manifest(Grant::new(Level::ReadOnly, Level::Allowlist, Level::None),
                                    Budget::research_default());
        manifest.actuation = Some(actuation_grant());
        let env = Environment::full();
        let sup = Supervisor::new(manifest, registry(), SimulatedPerimeterForTest::new(),
                                  ManualClock::new(), Limits::default());
        let mut ag = SkillScript { step: 0 };
        let report = sup.run(&env, &mut ag).unwrap();
        let nd = report.audit.to_ndjson().unwrap();
        assert!(nd.contains("skill_outcome"));     // the allowed move recorded an outcome
        assert!(nd.contains("not in the grant") || nd.contains("outside workspace")); // the denied move
        assert!(report.audit.verify().is_ok());
    }
```

Note: `SimulatedPerimeterForTest` and `registry`/`manifest` helpers already exist in the test module (see the existing `happy_path_reaches_goal_and_logs_everything` test for the exact constructors in this file — reuse them verbatim; if the existing perimeter test double has a different name, use that name).

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor skill_mediation_allows 2>&1 | tail -8
```
Expected: FAIL — no `AgentAction::RunSkill`, no `Agent::execute_skill`, no `SkillOutcome`.

- [ ] **Step 3: Add `SkillOutcome`, the action variant, the trait hook, and the loop arm**

In `lex-os/crates/lex-os-supervisor/src/lib.rs`:

a) Add a public struct near `Decision` (around line 135):

```rust
/// The observed result of executing an approved skill (returned by the
/// agent's `execute_skill` hook, recorded to the audit log).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillOutcome {
    pub outcome: String,
    pub observation: String,
}
```

b) Add a variant to `AgentAction` (after `Run`, around line 81):

```rust
    /// Request a mediated robot skill with structured arguments.
    RunSkill { skill: String, args: serde_json::Value },
```

c) Add a default-no-op hook to the `Agent` trait (after `on_reprovision`, around line 117):

```rust
    /// Deliver the supervisor's decision to the agent and, when allowed,
    /// return the outcome of executing the effect. Host-side agents that do
    /// not execute in a guest leave this as the default (`None`). The vsock
    /// agent overrides it to drive the in-guest effect over the transport.
    fn execute_skill(&mut self, _decision: &Decision) -> Option<SkillOutcome> {
        None
    }
```

d) Add a match arm in the run loop, alongside the existing `AgentAction::Run(name) => ...` arm (around line 311). Insert after that arm:

```rust
                AgentAction::RunSkill { skill, args } => {
                    let verdict = match &self.manifest.actuation {
                        Some(act) => skill::mediate_skill(act, &skill, &args),
                        None => skill::SkillVerdict::Denied(
                            "manifest has no actuation grant".into(),
                        ),
                    };
                    // Log the request (reuse CommandRequested with the skill name).
                    audit.append(Event::CommandRequested {
                        seq: ledger.commands_used(),
                        command: skill.clone(),
                        reversibility: "irreversible-bounded".into(),
                    });
                    match verdict {
                        skill::SkillVerdict::Denied(reason) => {
                            audit.append(Event::CommandDenied {
                                command: skill.clone(),
                                reason: reason.clone(),
                            });
                            // Tell the guest not to execute.
                            agent.execute_skill(&Decision::Denied(reason.clone()));
                            last_outcome = Some(format!("`{skill}` denied: {reason}"));
                        }
                        skill::SkillVerdict::Allowed => {
                            // Budget gate before the effect (one command).
                            let charge = Charge { commands: 1, money_cents: 0, api_calls: 1 };
                            if let Some(which) = ledger.would_exceed(&charge) {
                                audit.append(Event::BudgetExhausted { which: which.clone() });
                                agent.execute_skill(&Decision::BudgetExhausted(which.clone()));
                                break Outcome::BudgetExhausted(which);
                            }
                            ledger.charge(&charge);
                            audit.append(Event::BudgetCharged {
                                commands: ledger.commands_used(),
                                money_cents: ledger.money_used_cents(),
                                api_calls: ledger.api_calls_used(),
                                elapsed_secs: ledger.elapsed_secs(self.clock.now_secs()),
                            });
                            audit.append(Event::CommandAllowed { command: skill.clone() });
                            // Drive the effect (in-guest for vsock; canned in tests).
                            match agent.execute_skill(&Decision::Allowed) {
                                Some(o) => {
                                    audit.append(Event::SkillOutcome {
                                        command: skill.clone(),
                                        outcome: o.outcome.clone(),
                                        observation: o.observation.clone(),
                                    });
                                    checkpoint.completed.push(skill.clone());
                                    last_outcome = Some(format!("`{skill}` -> {}", o.outcome));
                                }
                                None => {
                                    last_outcome = Some(format!("`{skill}` allowed (no outcome reported)"));
                                }
                            }
                        }
                    }
                }
```

Note: this arm uses `Charge`, `Event`, `ledger`, `audit`, `checkpoint`, `last_outcome` exactly as the existing `mediate`/run-loop code does — see `lib.rs:416-435` for the charge pattern. `Charge` is already imported via `pub use budget::{BudgetLedger, Charge}`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor 2>&1 | tail -10
```
Expected: all supervisor tests pass (existing + the new one).

- [ ] **Step 5: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-supervisor/src/lib.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(supervisor): RunSkill mediation + execute_skill hook + outcome audit"
```

### Task 8: `VsockAgent::execute_skill` — drive the effect over the transport

**Files:**
- Modify: `lex-os/crates/lex-os-supervisor/src/vsock_agent.rs`

- [ ] **Step 1: Read the current VsockAgent to match its field names**

```bash
sed -n '1,80p' /home/alpibru/workspace/alpibrusl/lex-os/crates/lex-os-supervisor/src/vsock_agent.rs
```
Note the transport field name (e.g. `transport`) and how `next_action` currently calls `send_view`/`recv_action`.

- [ ] **Step 2: Write the failing test**

Add to the `tests` mod in `vsock_agent.rs` (or create one), using the simulated pair so no real vsock is needed:

```rust
    #[test]
    fn execute_skill_relays_decision_and_returns_outcome() {
        use lex_os_proto::transport::{simulated_pair, GuestTransport};
        use lex_os_proto::msg::{SkillDecisionMsg, SkillOutcomeMsg};
        use crate::{Agent, Decision};

        let (host, mut guest) = simulated_pair();
        let mut agent = VsockAgent::new(Box::new(host));

        // Guest side: expect a decision, then reply with an outcome.
        let guest_thread = std::thread::spawn(move || {
            let d: SkillDecisionMsg = guest.recv_decision().unwrap();
            assert!(d.allowed);
            guest.send_outcome(&SkillOutcomeMsg {
                outcome: "reached".into(), observation: "{\"coverage\":0.9}".into(),
            }).unwrap();
        });

        let out = agent.execute_skill(&Decision::Allowed).unwrap();
        assert_eq!(out.outcome, "reached");
        guest_thread.join().unwrap();
    }
```

(If `VsockAgent::new` takes a different argument shape, match the existing constructor; the point is a `VsockAgent` wrapping the simulated host transport.)

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor execute_skill_relays 2>&1 | tail -6
```
Expected: FAIL — `execute_skill` not overridden (default returns `None`, so `.unwrap()` panics or the decision is never sent).

- [ ] **Step 4: Override `execute_skill` on `VsockAgent`**

In the `impl Agent for VsockAgent` block, add (using the transport field name from Step 1, shown here as `self.transport`):

```rust
    fn execute_skill(&mut self, decision: &crate::Decision) -> Option<crate::SkillOutcome> {
        use lex_os_proto::msg::SkillDecisionMsg;
        let (allowed, reason) = match decision {
            crate::Decision::Allowed => (true, None),
            crate::Decision::Denied(r) => (false, Some(r.clone())),
            crate::Decision::BudgetExhausted(r) => (false, Some(r.clone())),
        };
        if self.transport.send_decision(&SkillDecisionMsg { allowed, reason }).is_err() {
            return None;
        }
        if !allowed {
            return None; // guest will not execute; nothing to await
        }
        match self.transport.recv_outcome() {
            Ok(o) => Some(crate::SkillOutcome { outcome: o.outcome, observation: o.observation }),
            Err(_) => None,
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-supervisor 2>&1 | tail -8
```
Expected: all supervisor tests pass.

- [ ] **Step 6: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-supervisor/src/vsock_agent.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(supervisor): VsockAgent.execute_skill drives the in-guest effect"
```

---

## Phase 4: Guest robot agent (lex-os-guest)

### Task 9: Robot script modes + sidecar HTTP call

**Files:**
- Modify: `lex-os/crates/lex-os-guest/src/main.rs`

- [ ] **Step 1: Write a pure unit test for the scripted decision**

Add a `#[cfg(test)]` block at the bottom of `main.rs` testing the script decision function (pure, no I/O):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use lex_os_proto::msg::AgentViewMsg;

    fn view(step: u64, completed: &[&str]) -> AgentViewMsg {
        AgentViewMsg {
            goal: "pick-place".into(), step,
            last_outcome: None,
            completed: completed.iter().map(|s| s.to_string()).collect(),
            reprovisions: 0,
        }
    }

    #[test]
    fn robot_demo_runs_skills_in_order_then_done() {
        // Fresh: first move_to.
        assert!(matches!(robot_action("robot-demo", &view(1, &[])),
            AgentActionMsg::RunSkill { ref skill, .. } if skill == "move_to"));
        // After move_to + grasp + run_policy completed: done.
        assert!(matches!(
            robot_action("robot-demo", &view(4, &["move_to", "grasp", "run_policy"])),
            AgentActionMsg::Done));
    }

    #[test]
    fn robot_violation_requests_out_of_workspace_move() {
        match robot_action("robot-violation", &view(1, &[])) {
            AgentActionMsg::RunSkill { skill, args } => {
                assert_eq!(skill, "move_to");
                assert!(args.get("x").unwrap().as_f64().unwrap() > 0.5);
            }
            other => panic!("expected out-of-workspace move, got {other:?}"),
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-guest robot_ 2>&1 | tail -6
```
Expected: FAIL — `robot_action` not defined.

- [ ] **Step 3: Implement the robot script + run loop**

In `lex-os/crates/lex-os-guest/src/main.rs`:

a) In `main()`, route the new scripts before the Ollama loop (after the existing `if script == "reprovision-demo"` block, around line 56):

```rust
    if script == "robot-demo" || script == "robot-violation" {
        return run_robot(transport.as_mut(), &script, &sidecar_url());
    }
```

b) Add a sidecar URL helper near `connect_transport`:

```rust
/// The sidecar endpoint as seen from inside the guest. Defaults to the
/// tap-side host IP (the same address the Ollama path uses) and the
/// sidecar's default port. Override with LEX_ROBOT_SIDECAR.
fn sidecar_url() -> String {
    std::env::var("LEX_ROBOT_SIDECAR").unwrap_or_else(|_| "http://10.0.2.2:8900".into())
}
```

c) Add the scripted decision function:

```rust
/// Deterministic robot planner. `robot-demo` walks the in-grant happy path;
/// `robot-violation` issues a single out-of-workspace move to prove the
/// supervisor's run-time Denied.
fn robot_action(script: &str, view: &AgentViewMsg) -> AgentActionMsg {
    let done = |c: &str| view.completed.iter().any(|x| x == c);
    if script == "robot-violation" {
        // One out-of-workspace move (x=0.9 is outside [0.1,0.5]); then done.
        if !done("move_to") {
            return AgentActionMsg::RunSkill {
                skill: "move_to".into(),
                args: serde_json::json!({"x": 0.9, "y": 0.0, "z": 0.2}),
            };
        }
        return AgentActionMsg::Done;
    }
    // robot-demo happy path: move_to -> grasp -> run_policy -> done.
    if !done("move_to") {
        AgentActionMsg::RunSkill { skill: "move_to".into(),
            args: serde_json::json!({"x": 0.3, "y": 0.0, "z": 0.2}) }
    } else if !done("grasp") {
        AgentActionMsg::RunSkill { skill: "grasp".into(),
            args: serde_json::json!({"force": 10.0}) }
    } else if !done("run_policy") {
        AgentActionMsg::RunSkill { skill: "run_policy".into(),
            args: serde_json::json!({"name": "lerobot/diffusion_pusht", "goal": "solve", "budget_ms": 10000}) }
    } else {
        AgentActionMsg::Done
    }
}
```

d) Add the run loop that implements the handshake (propose → recv decision → execute via sidecar → send outcome):

```rust
fn run_robot(transport: &mut dyn GuestTransport, script: &str, sidecar: &str) -> anyhow::Result<()> {
    loop {
        let view = transport.recv_view().context("recv view")?;
        let action = robot_action(script, &view);
        eprintln!("[guest:robot] step={} completed={:?} -> {action:?}", view.step, view.completed);
        let terminal = matches!(action, AgentActionMsg::Done | AgentActionMsg::Destroy { .. });
        // For a skill, we need the (skill, args) to execute on Allowed.
        let pending = if let AgentActionMsg::RunSkill { skill, args } = &action {
            Some((skill.clone(), args.clone()))
        } else { None };
        transport.send_action(&action).context("send action")?;
        if terminal { break; }
        if let Some((skill, args)) = pending {
            let decision = transport.recv_decision().context("recv decision")?;
            if decision.allowed {
                let observation = call_sidecar(sidecar, &skill, &args)
                    .unwrap_or_else(|e| format!("{{\"outcome\":\"stalled\",\"detail\":\"{e}\"}}"));
                let outcome = parse_outcome(&observation);
                transport.send_outcome(&lex_os_proto::msg::SkillOutcomeMsg {
                    outcome, observation,
                }).context("send outcome")?;
            } else {
                eprintln!("[guest:robot] denied: {:?}", decision.reason);
            }
        }
    }
    eprintln!("[guest:robot] loop complete");
    Ok(())
}

/// POST the skill to the sidecar; return the raw JSON body as a string.
fn call_sidecar(base: &str, skill: &str, args: &Value) -> anyhow::Result<String> {
    let url = format!("{base}/skill/{skill}");
    let resp = ureq::post(&url).send_json(args.clone()).context("sidecar request")?;
    Ok(resp.into_string().context("sidecar body")?)
}

/// Pull the `outcome` field out of the sidecar JSON; default to "reached"
/// for sense skills that return no outcome field.
fn parse_outcome(body: &str) -> String {
    serde_json::from_str::<Value>(body).ok()
        .and_then(|v| v.get("outcome").and_then(|o| o.as_str()).map(str::to_string))
        .unwrap_or_else(|| "reached".into())
}
```

Add `use lex_os_proto::transport::GuestTransport;` to the imports if not already present (it is used by the existing reprovision demo, so likely already imported).

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo test -p lex-os-guest 2>&1 | tail -8
```
Expected: robot tests pass.

- [ ] **Step 5: Verify the guest builds for musl (the in-VM target)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo build -p lex-os-guest --target x86_64-unknown-linux-musl --features vsock 2>&1 | tail -5
```
Expected: `Finished`. (`ureq` is already a guest dependency for the Ollama path, so no new crate is needed.)

- [ ] **Step 6: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os-guest/src/main.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(guest): robot-demo/robot-violation scripts + sidecar execution"
```

---

## Phase 5: CLI wiring (lex-os)

### Task 10: `--agent robot` dispatch

**Files:**
- Modify: `lex-os/crates/lex-os/src/main.rs`

- [ ] **Step 1: Read the AgentBackend enum + the Guest dispatch arm**

```bash
grep -n "enum AgentBackend\|AgentBackend::\|Guest =>" /home/alpibru/workspace/alpibrusl/lex-os/crates/lex-os/src/main.rs | head
sed -n '540,640p' /home/alpibru/workspace/alpibrusl/lex-os/crates/lex-os/src/main.rs
```
Note how `AgentBackend::Guest` builds the supervisor + guest subprocess/vsock and runs it. The Robot arm reuses that wiring with the robot script forced.

- [ ] **Step 2: Add a `Robot` variant to `AgentBackend`**

Find the `enum AgentBackend` (a `clap::ValueEnum`) and add:

```rust
    /// In-guest robot agent that issues move_to/grasp/run_policy as
    /// supervisor-mediated skills against the gym sidecar.
    Robot,
```

- [ ] **Step 3: Add the dispatch arm**

In `cmd_run`'s `match agent_backend`, add a `AgentBackend::Robot =>` arm that mirrors the `AgentBackend::Guest` arm but sets the guest script to the robot script (default `robot-demo`, overridable by `--guest-script`). Concretely, reuse the Guest arm's body but force the script env/arg. The simplest implementation: in the `AgentBackend::Robot` arm, set `let guest_script = Some(guest_script.unwrap_or_else(|| "robot-demo".into()));` then run the identical guest-launch code as the `Guest` arm. Copy the `Guest` arm body verbatim (per the no-"similar to" rule) and substitute that script default.

- [ ] **Step 4: Build the CLI**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo build -p lex-os --features firecracker 2>&1 | tail -5
GIT_CONFIG_NOSYSTEM=1 cargo run -p lex-os -- run --help 2>&1 | grep -A2 'agent'
```
Expected: `Finished`; `--agent` help lists `robot`.

- [ ] **Step 5: Smoke the robot agent against the simulated perimeter + a live sidecar (no KVM needed)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
python3 sidecar/gym_sidecar.py & SIDECAR=$!
sleep 8
cd /home/alpibru/workspace/alpibrusl/lex-os
LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 \
  GIT_CONFIG_NOSYSTEM=1 cargo run -p lex-os -- run \
  --manifest ../lex-robot/manifests/pick_place.capsule.json \
  --agent robot --simulated --audit-out /tmp/robot-audit.json 2>&1 | tail -20
kill $SIDECAR
grep -o 'skill_outcome' /tmp/robot-audit.json | head -1
```
Expected: a run that mediates the skills and writes an audit log containing `skill_outcome` entries. (The simulated perimeter is NOT a security boundary — this only validates the wiring; the real boundary is Phase 9.) Note: this requires the `pick_place.capsule.json` actuation block from Task 11 — do Task 11 first if running this step.

- [ ] **Step 6: Commit**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add crates/lex-os/src/main.rs
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(cli): --agent robot dispatch"
```

---

## Phase 6: Sidecar reachability + lex-trail episode log (lex-robot)

### Task 11: Add the actuation block + reconcile egress in the manifest

**Files:**
- Modify: `lex-robot/manifests/pick_place.capsule.json`

- [ ] **Step 1: Write the actuation block + egress**

Replace `lex-robot/manifests/pick_place.capsule.json` with:

```json
{
  "goal": {
    "description": "Pick the red block and place it in the bin (gym-pusht: push the T to the goal)",
    "done_signal": null
  },
  "grant": {
    "filesystem": "ReadWrite",
    "network": "Allowlist",
    "exec": "None"
  },
  "budget": {
    "wall_clock_secs": 120,
    "max_commands": 200,
    "max_money_cents": 0,
    "max_api_calls": 200
  },
  "isolation_floor": "Namespace",
  "egress": ["10.0.2.2:8900"],
  "actuation": {
    "skills": ["read_joints", "read_camera", "move_to", "grasp", "run_policy"],
    "arm": {
      "workspace_m": [
        {"min": 0.1, "max": 0.5},
        {"min": -0.3, "max": 0.3},
        {"min": 0.0, "max": 0.4}
      ],
      "max_velocity_mps": 0.25,
      "max_force_n": 15.0
    },
    "gripper": {"max_grip_force_n": 20.0}
  }
}
```

Note: `max_api_calls` was `0` in the original manifest, but Task 7's skill arm charges 1 api-call per skill (so the network sub-budget is meaningful). The JSON above already sets `"max_api_calls": 200` to keep in-grant skills from being budget-blocked. This value must stay ≥ the number of skills a run issues.

- [ ] **Step 2: Verify the manifest loads (round-trips through the Rust loader)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
GIT_CONFIG_NOSYSTEM=1 cargo run -p lex-os -- resolve --manifest ../lex-robot/manifests/pick_place.capsule.json 2>&1 | tail -6
```
Expected: resolves without a parse error (the `actuation` block deserializes via the new optional field).

- [ ] **Step 3: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add manifests/pick_place.capsule.json
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(manifest): add actuation block + guest-visible egress"
```

### Task 12: lex-trail content-addressed emitter (Python)

**Files:**
- Create: `lex-robot/sidecar/trail.py`
- Test: `lex-robot/sidecar/test_trail.py`

- [ ] **Step 1: Write the failing test**

Create `lex-robot/sidecar/test_trail.py`:

```python
import hashlib
from trail import Trail, compute_id

def test_compute_id_matches_lex_trail_formula():
    # Mirror lex-trail/src/event.lex: sha256 of join([kind, parent, payload, ts], " ").
    expected = hashlib.sha256(b"cap.invoked  {} 0").hexdigest()
    assert compute_id("cap.invoked", None, "{}", 0) == expected

def test_chain_links_parent_to_prev_id():
    t = Trail()
    e1 = t.emit("cap.invoked", '{"capability":"move_to"}', ts_ms=1)
    e2 = t.emit("cap.completed", '{"capability":"move_to","result":"reached"}', ts_ms=2)
    assert e2["parent"] == e1["id"]
    assert t.verify()

def test_verify_detects_tampering():
    t = Trail()
    t.emit("cap.invoked", "{}", ts_ms=1)
    t.events[0]["payload_json"] = "{\"tampered\":true}"
    assert not t.verify()
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/sidecar
python3 -m pytest test_trail.py -q 2>&1 | tail -6
```
Expected: FAIL — no module `trail`.

- [ ] **Step 3: Implement `trail.py`**

Create `lex-robot/sidecar/trail.py`:

```python
"""Content-addressed event log — a Python mirror of lex-trail/src/event.lex.

Each event id is sha256(join([kind, parent_or_empty, payload_json, ts_ms], " ")),
and events chain via `parent` = the previous event's id. This lets the boxed
run emit a genuine lex-trail chain that lex-trail's replay/export can read and
that scripts/reconcile_audit.py can corroborate against the lex-os audit log.
"""
import hashlib
from typing import Optional


def compute_id(kind: str, parent: Optional[str], payload_json: str, ts_ms: int) -> str:
    p = parent if parent is not None else ""
    canonical = " ".join([kind, p, payload_json, str(ts_ms)])
    return hashlib.sha256(canonical.encode()).hexdigest()


class Trail:
    def __init__(self) -> None:
        self.events: list[dict] = []

    def emit(self, kind: str, payload_json: str, ts_ms: int) -> dict:
        parent = self.events[-1]["id"] if self.events else None
        evt = {
            "id": compute_id(kind, parent, payload_json, ts_ms),
            "kind": kind,
            "parent": parent,
            "payload_json": payload_json,
            "ts_ms": ts_ms,
        }
        self.events.append(evt)
        return evt

    def verify(self) -> bool:
        prev = None
        for e in self.events:
            if e["parent"] != prev:
                return False
            if e["id"] != compute_id(e["kind"], e["parent"], e["payload_json"], e["ts_ms"]):
                return False
            prev = e["id"]
        return True

    def to_json(self) -> str:
        import json
        return json.dumps(self.events, indent=2)
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/sidecar
python3 -m pytest test_trail.py -q 2>&1 | tail -6
```
Expected: 3 tests pass.

- [ ] **Step 5: Cross-check the id formula against the real lex-trail (optional but recommended)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-trail
grep -n 'sha256_str\|str.join' src/event.lex
```
Confirm the formula in `compute_id` (kind, parent, payload, ts joined by a single space) matches `event.lex`'s `compute_id`. (As read: `crypto.sha256_str(str.join([kind, p, payload_json, int.to_str(ts_ms)], " "))`.)

- [ ] **Step 6: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add sidecar/trail.py sidecar/test_trail.py
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(sidecar): lex-trail content-addressed episode emitter"
```

### Task 13: Sidecar binds to a guest-reachable host + emits the episode log

**Files:**
- Modify: `lex-robot/sidecar/gym_sidecar.py`

- [ ] **Step 1: Write the failing test**

Create `lex-robot/sidecar/test_sidecar_trail.py`:

```python
import importlib, os

def test_host_is_configurable(monkeypatch):
    monkeypatch.setenv("LEX_ROBOT_SIDECAR_HOST", "0.0.0.0")
    import gym_sidecar
    importlib.reload(gym_sidecar)
    assert gym_sidecar.HOST == "0.0.0.0"

def test_skill_call_records_trail_event(monkeypatch):
    import gym_sidecar
    importlib.reload(gym_sidecar)
    # A skill call appends cap.invoked + cap.completed to the episode trail.
    before = len(gym_sidecar.EPISODE.events)
    gym_sidecar.record_skill_trail("move_to", {"x": 0.3}, {"outcome": "reached"})
    assert len(gym_sidecar.EPISODE.events) == before + 2
    assert gym_sidecar.EPISODE.events[-2]["kind"] == "cap.invoked"
    assert gym_sidecar.EPISODE.events[-1]["kind"] == "cap.completed"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/sidecar
python3 -m pytest test_sidecar_trail.py -q 2>&1 | tail -6
```
Expected: FAIL — `LEX_ROBOT_SIDECAR_HOST` not read; `record_skill_trail`/`EPISODE` not defined.

- [ ] **Step 3: Implement the host override + episode trail**

In `lex-robot/sidecar/gym_sidecar.py`:

a) Change the host line (line 40) to read the env:

```python
HOST = os.environ.get("LEX_ROBOT_SIDECAR_HOST", "127.0.0.1")
```

b) After the imports, add the episode trail and a monotonic counter (avoids wall-clock in the deterministic test):

```python
from trail import Trail
EPISODE = Trail()
_TS = {"n": 0}

def _next_ts() -> int:
    _TS["n"] += 1
    return _TS["n"]

def record_skill_trail(name: str, args: dict, result: dict) -> None:
    """Append a cap.invoked + cap.completed pair for one skill call."""
    EPISODE.emit("cap.invoked",
                 json.dumps({"capability": name, "args": args}, sort_keys=True),
                 ts_ms=_next_ts())
    outcome = result.get("outcome", "reached")
    EPISODE.emit("cap.completed",
                 json.dumps({"capability": name, "result": outcome}, sort_keys=True),
                 ts_ms=_next_ts())
```

c) In `Handler.do_POST`, after computing `result` under the lock, record the trail and (best-effort) flush it to disk:

```python
            with _SKILL_LOCK:
                result = handle_skill(name, args)
                record_skill_trail(name, args, result)
                trail_path = os.environ.get("LEX_ROBOT_TRAIL", "/tmp/robot-trail.json")
                try:
                    with open(trail_path, "w") as f:
                        f.write(EPISODE.to_json())
                except OSError:
                    pass
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/sidecar
python3 -m pytest test_sidecar_trail.py test_trail.py -q 2>&1 | tail -6
```
Expected: tests pass.

- [ ] **Step 5: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add sidecar/gym_sidecar.py sidecar/test_sidecar_trail.py
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(sidecar): guest-reachable host + lex-trail episode log"
```

---

## Phase 7: Reconcile the two audit chains (lex-robot)

### Task 14: `reconcile_audit.py` — assert the logs corroborate

**Files:**
- Create: `lex-robot/scripts/reconcile_audit.py`
- Test: `lex-robot/scripts/test_reconcile.py`

- [ ] **Step 1: Write the failing test**

Create `lex-robot/scripts/test_reconcile.py`:

```python
import json
from reconcile_audit import skill_sequence_from_audit, skill_sequence_from_trail, reconcile

def test_extracts_and_matches_sequences(tmp_path):
    # lex-os audit: ndjson Entry lines with command_allowed + skill_outcome events.
    audit = [
        {"event": {"kind": "command_allowed", "command": "move_to"}},
        {"event": {"kind": "skill_outcome", "command": "move_to", "outcome": "reached", "observation": "{}"}},
        {"event": {"kind": "command_allowed", "command": "grasp"}},
        {"event": {"kind": "skill_outcome", "command": "grasp", "outcome": "stalled", "observation": "{}"}},
    ]
    trail = [
        {"kind": "cap.invoked", "payload_json": json.dumps({"capability": "move_to"})},
        {"kind": "cap.completed", "payload_json": json.dumps({"capability": "move_to", "result": "reached"})},
        {"kind": "cap.invoked", "payload_json": json.dumps({"capability": "grasp"})},
        {"kind": "cap.completed", "payload_json": json.dumps({"capability": "grasp", "result": "stalled"})},
    ]
    assert skill_sequence_from_audit(audit) == [("move_to", "reached"), ("grasp", "stalled")]
    assert skill_sequence_from_trail(trail) == [("move_to", "reached"), ("grasp", "stalled")]
    assert reconcile(audit, trail) == []  # no discrepancies

def test_detects_divergence():
    audit = [{"event": {"kind": "skill_outcome", "command": "move_to", "outcome": "reached", "observation": "{}"}}]
    trail = [{"kind": "cap.completed", "payload_json": json.dumps({"capability": "move_to", "result": "timeout"})}]
    assert reconcile(audit, trail)  # non-empty: outcomes disagree
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/scripts
python3 -m pytest test_reconcile.py -q 2>&1 | tail -6
```
Expected: FAIL — no module `reconcile_audit`.

- [ ] **Step 3: Implement `reconcile_audit.py`**

Create `lex-robot/scripts/reconcile_audit.py`:

```python
#!/usr/bin/env python3
"""Reconcile the lex-os audit log with the sidecar's lex-trail episode log.

The two are produced independently — the supervisor records each mediated
skill + observed outcome (lex-os audit, hash-chained), and the sidecar records
each executed skill + result (lex-trail, content-addressed). For a boxed run
they must corroborate: same skill sequence, same outcomes. Any divergence is a
sign the effect plane and the control plane disagree.

Usage:
    reconcile_audit.py <lex-os-audit.json> <robot-trail.json>
Exit 0 when the chains corroborate; exit 1 (and print discrepancies) otherwise.
"""
import json
import sys


def skill_sequence_from_audit(entries: list) -> list:
    """(skill, outcome) pairs from a lex-os audit log (list of Entry dicts)."""
    out = []
    for e in entries:
        ev = e.get("event", e)
        if ev.get("kind") == "skill_outcome":
            out.append((ev["command"], ev["outcome"]))
    return out


def skill_sequence_from_trail(events: list) -> list:
    """(skill, result) pairs from cap.completed events in a lex-trail chain."""
    out = []
    for ev in events:
        if ev.get("kind") == "cap.completed":
            p = json.loads(ev["payload_json"])
            out.append((p["capability"], p["result"]))
    return out


def reconcile(audit: list, trail: list) -> list:
    """Return a list of human-readable discrepancies (empty == corroborated)."""
    a = skill_sequence_from_audit(audit)
    t = skill_sequence_from_trail(trail)
    problems = []
    if len(a) != len(t):
        problems.append(f"length mismatch: audit has {len(a)} skill outcomes, trail has {len(t)}")
    for i, (ae, te) in enumerate(zip(a, t)):
        if ae != te:
            problems.append(f"step {i}: audit {ae} != trail {te}")
    return problems


def _load(path: str) -> list:
    with open(path) as f:
        text = f.read()
    # lex-os audit may be a JSON array (to_json) or ndjson (to_ndjson); accept both.
    text = text.strip()
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    audit = _load(sys.argv[1])
    trail = _load(sys.argv[2])
    problems = reconcile(audit, trail)
    if problems:
        print("DISCREPANCIES:")
        for p in problems:
            print(" -", p)
        return 1
    print(f"OK: {len(skill_sequence_from_audit(audit))} skill outcomes corroborate across both chains")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot/scripts
python3 -m pytest test_reconcile.py -q 2>&1 | tail -6
```
Expected: 2 tests pass.

- [ ] **Step 5: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add scripts/reconcile_audit.py scripts/test_reconcile.py
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(scripts): reconcile lex-os audit with lex-trail episode log"
```

---

## Phase 8: End-to-end on the simulated perimeter (no KVM)

This phase proves the whole control+effect+audit+reconcile pipeline works before involving Firecracker. It is the GPU-free, KVM-free integration gate.

### Task 15: Simulated end-to-end run + reconcile

**Files:**
- Create: `lex-robot/box/sim_e2e.sh`

- [ ] **Step 1: Write the script**

Create `lex-robot/box/sim_e2e.sh`:

```bash
#!/usr/bin/env bash
# End-to-end on the SIMULATED perimeter (no KVM, no GPU): proves the robot
# agent proposes skills, the supervisor mediates + audits, the guest executes
# against the sidecar, and the two audit chains corroborate.
#
# NOT a security boundary — see box/README.md §4 for the real Firecracker run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXOS="$ROOT/../lex-os"
M="$ROOT/manifests/pick_place.capsule.json"
AUDIT=/tmp/robot-audit.json
TRAIL=/tmp/robot-trail.json

cd "$ROOT"
LEX_ROBOT_TRAIL="$TRAIL" python3 sidecar/gym_sidecar.py & SIDECAR=$!
trap 'kill $SIDECAR 2>/dev/null || true' EXIT
sleep 8

cd "$LEXOS"
LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 \
  GIT_CONFIG_NOSYSTEM=1 cargo run -q -p lex-os -- run \
  --manifest "$M" --agent robot --simulated --audit-out "$AUDIT"

echo "== reconcile =="
python3 "$ROOT/scripts/reconcile_audit.py" "$AUDIT" "$TRAIL"
```

- [ ] **Step 2: Make it executable and run it**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
chmod +x box/sim_e2e.sh
./box/sim_e2e.sh 2>&1 | tail -25
```
Expected: the run completes, the audit log is written with `skill_outcome` entries, and reconcile prints `OK: N skill outcomes corroborate`.

- [ ] **Step 3: Run the violation variant and confirm the run-time Denied**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
python3 sidecar/gym_sidecar.py & SIDECAR=$!
sleep 8
cd ../lex-os
LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 \
  GIT_CONFIG_NOSYSTEM=1 cargo run -q -p lex-os -- run \
  --manifest ../lex-robot/manifests/pick_place.capsule.json \
  --agent robot --guest-script robot-violation --simulated --audit-out /tmp/robot-viol.json 2>&1 | tail -10
kill $SIDECAR
grep -o 'outside workspace' /tmp/robot-viol.json | head -1
```
Expected: the audit log contains a `command_denied` with an "outside workspace" reason — the out-of-grant move blocked at run time (not at `lex check`).

- [ ] **Step 4: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add box/sim_e2e.sh
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "test(box): simulated end-to-end run + reconcile harness"
```

---

## Phase 9: Real Firecracker box (Linux+KVM, root) — the issue's verification matrix

These steps require root/jailer and the fetched assets; they are the hardware-enforced run. They are runbook verification, not unit tests.

### Task 16: Fetch assets + build the guest into the rootfs

**Files:** none (uses lex-os `demo/setup-assets.sh`).

- [ ] **Step 1: Fetch firecracker + jailer + kernel + rootfs**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
sudo bash demo/setup-assets.sh 2>&1 | tail -15
```
Expected: firecracker, jailer, a kernel image, and a rootfs are installed where the perimeter expects them (see `demo/setup-assets.sh` output for paths).

- [ ] **Step 2: Confirm the existing kernel egress wall demo still passes (baseline)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
sudo bash demo/wall2.sh 2>&1 | tail -15
```
Expected: a jailed microVM boots and a non-allowlisted host is dropped — the kernel egress wall baseline.

No commit.

### Task 17: Run the robot task inside the microVM (verify a/b/c)

**Files:**
- Create: `lex-robot/box/run_in_vm.sh`

- [ ] **Step 1: Write the runbook script**

Create `lex-robot/box/run_in_vm.sh`:

```bash
#!/usr/bin/env bash
# Hardware-enforced run: the robot task as a lex-os Firecracker guest.
# Requires: Linux + /dev/kvm + root (jailer) + assets (demo/setup-assets.sh)
# + the gym sidecar running on the host bound to the tap-side IP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXOS="$ROOT/../lex-os"
M="$ROOT/manifests/pick_place.capsule.json"
AUDIT=/tmp/robot-audit.json
TRAIL=/tmp/robot-trail.json

# Sidecar must be reachable from the guest at 10.0.2.2:8900 → bind to 0.0.0.0.
cd "$ROOT"
LEX_ROBOT_SIDECAR_HOST=0.0.0.0 LEX_ROBOT_TRAIL="$TRAIL" \
  python3 sidecar/gym_sidecar.py & SIDECAR=$!
trap 'kill $SIDECAR 2>/dev/null || true' EXIT
sleep 8

cd "$LEXOS"
# --jail-uid/--jail-gid run firecracker under the jailer; kvm gid lets the
# guest reach /dev/kvm. The guest binary (musl + vsock) is injected by the
# perimeter; build it first if setup-assets did not.
sudo -E "$LEXOS"/target/debug/lex-os run \
  --manifest "$M" --agent robot \
  --jail-uid "$(id -u)" --jail-gid "$(getent group kvm | cut -d: -f3)" \
  --audit-out "$AUDIT"

echo "== reconcile =="
python3 "$ROOT/scripts/reconcile_audit.py" "$AUDIT" "$TRAIL"
```

- [ ] **Step 2: (a) In-grant run completes + audit verifies**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
chmod +x box/run_in_vm.sh
sudo -E ./box/run_in_vm.sh 2>&1 | tail -25
```
Expected: the run completes inside the microVM; the output reports `audit_verified: true` and reconcile prints `OK`. The audit log shows `provisioned → command_requested → budget_charged → command_allowed → skill_outcome → … → session_ended`.

- [ ] **Step 3: (b) Budget breach → supervisor kill + reprovision**

Temporarily tighten the budget and re-run:

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
cp manifests/pick_place.capsule.json /tmp/tight.json
python3 - <<'PY'
import json
m = json.load(open("/tmp/tight.json"))
m["budget"]["max_commands"] = 1   # trips after the first skill
json.dump(m, open("/tmp/tight.json","w"))
PY
cd ../lex-os
sudo -E ./target/debug/lex-os run --manifest /tmp/tight.json --agent robot \
  --jail-uid "$(id -u)" --jail-gid "$(getent group kvm | cut -d: -f3)" \
  --audit-out /tmp/robot-budget.json 2>&1 | tail -15
grep -o 'BudgetExhausted\|budget_exhausted' /tmp/robot-budget.json | head -1
```
Expected: outcome `BudgetExhausted("commands")`; the audit log shows the supervisor halted the box. (Reprovision-on-failure is already demonstrated by lex-os's existing reprovision path; the budget halt is the kill.)

- [ ] **Step 4: (c) Out-of-grant action blocked at the perimeter (run time)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-os
sudo -E ./target/debug/lex-os run --manifest ../lex-robot/manifests/pick_place.capsule.json \
  --agent robot --guest-script robot-violation \
  --jail-uid "$(id -u)" --jail-gid "$(getent group kvm | cut -d: -f3)" \
  --audit-out /tmp/robot-viol.json 2>&1 | tail -15
grep -o 'outside workspace' /tmp/robot-viol.json | head -1
```
Expected: a `command_denied` with "outside workspace" — the out-of-grant `move_to` blocked at run time inside the box, not at `lex check`. Combined with Task 16 Step 2 (kernel egress drop), this demonstrates both the logical and kernel walls.

- [ ] **Step 5: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add box/run_in_vm.sh
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "feat(box): hardware-enforced run script for lex-robot#1"
```

### Task 18: Update box/README §4 + close the loop

**Files:**
- Modify: `lex-robot/box/README.md`

- [ ] **Step 1: Replace §4**

In `lex-robot/box/README.md`, replace the `## 4. Remaining: hardware-enforced box (Linux+KVM) — lex-robot#1` section with a section documenting the real run: point at `box/run_in_vm.sh`, the sidecar-on-host requirement (`LEX_ROBOT_SIDECAR_HOST=0.0.0.0`, reached at `10.0.2.2:8900` from the guest), the three verification commands (a/b/c) from Task 17, and the reconcile step. State plainly that the policy *solve quality* (`run_policy` reaching a real PushT solve) is Issue #2 on a CUDA box, so this run proves mediation + execution + audit + reconcile, not a learned solve.

- [ ] **Step 2: Run the README-in-sync check**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
bash scripts/check_readme.sh 2>&1 | tail -10
```
Expected: passes (or update the README to satisfy it).

- [ ] **Step 3: Commit (in lex-robot)**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git add box/README.md
GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH=/usr/lib/git-core git commit -m "docs(box): document the hardware-enforced robot-in-box run (lex-robot#1)"
```

---

## Final verification (the issue's checklist)

Run end-to-end and confirm each issue #1 acceptance item:

- [ ] `lex-os check`/`resolve` still admit the in-grant program (no regression): `cargo run -p lex-os -- resolve --manifest ../lex-robot/manifests/pick_place.capsule.json`.
- [ ] Simulated e2e green: `./box/sim_e2e.sh` → reconcile `OK`.
- [ ] (a) Real in-grant run completes + `audit_verified: true`.
- [ ] (b) Budget breach → `BudgetExhausted` + kill.
- [ ] (c) Out-of-grant `move_to` → run-time `command_denied`; non-allowlisted host → kernel egress drop (`demo/wall2.sh`).
- [ ] lex-os audit ↔ lex-trail episode log corroborate (`reconcile_audit.py` → `OK`).
- [ ] Both repos' test suites green: `cargo test` (lex-os) and `python3 -m pytest sidecar scripts` (lex-robot).

**Deferred (tracked, not done here):** `run_policy` solving PushT at high reward (Issue #2, CUDA box); LLM / lex-loom-graph planner replacing the deterministic script.
