# lex-robot/budget.lex — the in-box budget supervisor. Pure: no effects, no I/O.
#
# DESIGN.md §6 / §9.5: the grant carries budgets (action count + wall-clock).
# lex-os enforces them around the whole box (manifests/*.capsule.json →
# BudgetExhausted), but the task loop also enforces them *itself* so a plain
# `lex run` self-limits — no supervisor, no KVM. This is the "supervisor budget
# kill" at the lex-robot layer.
#
# The ledger is a plain value threaded through the loop (Lex has no mutable
# cells): each actuating step `spend`s one action, and `breach` is checked
# *before* the next command leaves the box. Time is supplied by the caller
# (`now_ms`) so this module stays pure and unit-testable — only the loop in
# task.lex carries the `[time]` effect.

import "std.str" as str

import "std.int" as int

import "./types" as t

# A running tally for one task run. Caps are copied from the grant at `start`
# so the ledger is self-contained (the breach check needs no grant reference).
type Ledger = {
  actions_used :: Int,    # actuating commands issued so far
  started_ms   :: Int,    # wall-clock at run start (Unix millis)
  action_cap   :: Int,    # max actions (grant.budget_actions)
  wall_cap_ms  :: Int,    # max wall-clock in ms (grant.budget_wall_ms)
}

# Open a ledger for a run. `now_ms` is the caller's wall clock at start.
fn start(g :: t.Grant, now_ms :: Int) -> Ledger {
  {
    actions_used: 0,
    started_ms: now_ms,
    action_cap: g.budget_actions,
    wall_cap_ms: g.budget_wall_ms,
  }
}

# Charge one actuating command against the ledger.
fn spend(led :: Ledger) -> Ledger {
  {
    actions_used: led.actions_used + 1,
    started_ms: led.started_ms,
    action_cap: led.action_cap,
    wall_cap_ms: led.wall_cap_ms,
  }
}

# Has the run exhausted its budget as of `now_ms`? None = within budget;
# Some(reason) = breached (the reason is a human-legible string for the trail).
# Checked BEFORE issuing the next command: `actions_used >= action_cap` means
# the next action would be the (cap+1)-th, so it is refused.
fn breach(led :: Ledger, now_ms :: Int) -> Option[Str] {
  if led.actions_used >= led.action_cap {
    Some(str.join(
      ["action budget exhausted: ", int.to_str(led.actions_used), "/",
       int.to_str(led.action_cap), " actions used"], ""))
  } else {
    let elapsed := now_ms - led.started_ms
    if elapsed >= led.wall_cap_ms {
      Some(str.join(
        ["wall-clock budget exhausted: ", int.to_str(elapsed), "ms ≥ ",
         int.to_str(led.wall_cap_ms), "ms cap"], ""))
    } else {
      None
    }
  }
}
