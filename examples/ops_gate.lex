# examples/ops_gate.lex — governed agent operations (capability over tool-use).
#
# The kernel applied to the universal agentic domain: an agent calling tools/APIs.
# A did:lex agent runs a task as a sequence of tool calls under ONE capability
# token that bounds WHICH tools it may invoke (allow/deny), under a call budget
# and a stated purpose. Every call is gated — a forbidden tool or an over-budget
# call is refused BEFORE it runs — and attested to a hash-chained lex-trail, so
# the whole run replays and a third party can recompute that the agent never
# stepped outside its authority. A clean verified run earns the agent operator
# reputation (examples/reputation_run.sh feeds the did:lex registry).
#
# Same shape as the consent + capability gates — capability gating, here over
# ACTIONS-ON-TOOLS — so it plugs into the same trail + verifier + reputation
# kernel. The "audit-ready agent ops" use case, native, no new machinery.
#
# Env: OPS_TRAIL (trail output, default ops_trail.jsonl),
#      AGENT_DID (default did:lex:agent:assistant-1)
# Run: lex run --allow-effects io,sql,time,fs_write,env examples/ops_gate.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-games/src/arena/trail_file" as tf

# ── the operations capability (a2p-shaped, over tools) ───────────────────────
type OpPolicy = { agent_pattern :: Str, tools_allow :: List[Str], tools_deny :: List[Str], max_calls :: Int, require_purpose :: Bool }

fn assistant_ops() -> OpPolicy {
  { agent_pattern: "did:lex:agent:*", tools_allow: ["search", "calendar.read", "email.send", "docs.read"], tools_deny: ["files.delete", "payments.transfer"], max_calls: 4, require_purpose: true }
}

# A tool call the agent attempts.
type Call = { tool :: Str, args :: Str, purpose :: Str }

fn task() -> List[Call] {
  [{ tool: "search", args: "free slots next week", purpose: "schedule a meeting" }, { tool: "calendar.read", args: "this week", purpose: "schedule a meeting" }, { tool: "email.send", args: "invite to alice", purpose: "schedule a meeting" }, { tool: "payments.transfer", args: "$500 to vendor", purpose: "schedule a meeting" }, { tool: "docs.read", args: "agenda.md", purpose: "schedule a meeting" }, { tool: "search", args: "more slots", purpose: "schedule a meeting" }]
}

fn did(actor :: Str, id :: Str) -> Str {
  str.join(["did:lex:", actor, ":", id], "")
}

fn list_has(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (a :: Bool, s :: Str) -> Bool {
    a or s == x
  })
}

fn pattern_match(pat :: Str, agent :: Str) -> Bool {
  if str.ends_with(pat, "*") {
    str.starts_with(agent, str.slice(pat, 0, str.len(pat) - 1))
  } else {
    pat == agent
  }
}

fn tools_json(xs :: List[Str]) -> Str {
  str.join(["[", str.join(list.map(xs, fn (s :: Str) -> Str {
    str.join(["\"", s, "\""], "")
  }), ","), "]"], "")
}

fn policy_opened_json(p :: OpPolicy) -> Str {
  str.join(["{\"agent_pattern\":\"", p.agent_pattern, "\",\"tools_allow\":", tools_json(p.tools_allow), ",\"tools_deny\":", tools_json(p.tools_deny), ",\"max_calls\":", int.to_str(p.max_calls), ",\"require_purpose\":", if p.require_purpose {
    "true"
  } else {
    "false"
  }, "}"], "")
}

# decision: allow the call, or deny with a reason. `used` = ok calls so far.
type Decision = Allow | Deny(Str)

fn decide(p :: OpPolicy, agent :: Str, c :: Call, used :: Int) -> Decision {
  if not pattern_match(p.agent_pattern, agent) {
    Deny("agent not covered by token")
  } else {
    if not list_has(p.tools_allow, c.tool) or list_has(p.tools_deny, c.tool) {
      Deny("tool not permitted")
    } else {
      if p.require_purpose and str.is_empty(c.purpose) {
        Deny("a stated purpose is required")
      } else {
        if used >= p.max_calls {
          Deny("call budget exhausted")
        } else {
          Allow
        }
      }
    }
  }
}

fn op_json(agent :: Str, c :: Call) -> Str {
  str.join(["{\"agent_did\":\"", agent, "\",\"tool\":\"", c.tool, "\",\"args\":\"", c.args, "\",\"purpose\":\"", c.purpose, "\"}"], "")
}

fn ok_json(agent :: Str, c :: Call) -> Str {
  str.join(["{\"agent_did\":\"", agent, "\",\"tool\":\"", c.tool, "\"}"], "")
}

fn denied_json(agent :: Str, c :: Call, reason :: Str) -> Str {
  str.join(["{\"agent_did\":\"", agent, "\",\"tool\":\"", c.tool, "\",\"reason\":\"", reason, "\"}"], "")
}

# handle one call: record the request, gate it, record ok|denied; return new used.
fn handle(log :: trail.Log, p :: OpPolicy, agent :: Str, c :: Call, used :: Int) -> [io, sql, time] Int {
  let _r := trail.append(log, "op.requested", None, op_json(agent, c))
  match decide(p, agent, c, used) {
    Allow => {
      let _o := trail.append(log, "op.ok", None, ok_json(agent, c))
      let _l := io.print(str.join(["  🔧 ", c.tool, " (", c.args, ") → OK"], ""))
      used + 1
    },
    Deny(reason) => {
      let _d := trail.append(log, "op.denied", None, denied_json(agent, c, reason))
      let _l := io.print(str.join(["  🔧 ", c.tool, " (", c.args, ") → DENIED — ", reason], ""))
      used
    },
  }
}

fn run() -> [io, sql, time, fs_write, env] Nil {
  let trail_path := match env.get("OPS_TRAIL") {
    Some(v) => v,
    None => "ops_trail.jsonl",
  }
  let agent := match env.get("AGENT_DID") {
    Some(v) => v,
    None => did("agent", "assistant-1"),
  }
  let p := assistant_ops()
  let __lex_discard_1 := io.print(str.join(["=== Lex agent-ops gate — ", agent, " runs a task under a tool-use capability ===\n"], ""))
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let _po := match trail.append(log, "policy.opened", None, policy_opened_json(p)) {
        Err(e) => io.print(str.concat("policy.opened write failed: ", e)),
        Ok(_) => io.print(str.join(["token: may call ", tools_json(p.tools_allow), ", never ", tools_json(p.tools_deny), "; ≤", int.to_str(p.max_calls), " calls (purpose required)\n"], "")),
      }
      let _used := list.fold(task(), 0, fn (used :: Int, c :: Call) -> [io, sql, time] Int {
        handle(log, p, agent, c, used)
      })
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let _w := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event)))
          io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " op-trail events → ", trail_path], ""))
        },
      }
    },
  }
}

