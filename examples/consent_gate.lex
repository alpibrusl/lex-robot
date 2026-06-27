# examples/consent_gate.lex — a DID-identity consent gate with verifiable receipts.
#
# The platform kernel's first piece: who an agent is, and what data it may touch.
# This ports the *model* of the a2p (Agent-2-Profile) protocol natively into Lex
# — DIDs, scoped access policies, access requests, consent receipts — and adds the
# one thing a2p doesn't have: the receipt is a hash-chained lex-trail event, so a
# third party can REPLAY the session and recompute that every grant respected the
# policy. a2p says "consent was given"; Lex *proves* it. No dependency on a2p.
#
# It is the data-side twin of lex-guard's spend gate: capability gating, but over
# what an agent may KNOW (scopes) instead of what it may SPEND. Same shape —
# policy.opened → request → granted | denied — verified by lex-games' consent
# verifier (examples/consent_verify.lex).
#
# Env: CONSENT_TRAIL (trail output path, default consent_trail.jsonl)
# Run: lex run --allow-effects io,sql,time,fs_write,env examples/consent_gate.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-games/src/arena/trail_file" as tf

# ── DIDs (did:lex:<actor>:<id>) — portable, user-controlled identity ─────────
fn did(actor :: Str, id :: Str) -> Str {
  str.join(["did:lex:", actor, ":", id], "")
}

fn is_did(s :: Str) -> Bool {
  str.starts_with(s, "did:lex:")
}

# glob match for an agent pattern ending in '*' (else exact).
fn pattern_match(pat :: Str, agent :: Str) -> Bool {
  if str.ends_with(pat, "*") {
    str.starts_with(agent, str.slice(pat, 0, str.len(pat) - 1))
  } else {
    pat == agent
  }
}

# ── the access policy (a2p-shaped: allow/deny scopes + a purpose requirement) ─
type Policy = { agent_pattern :: Str, allow :: List[Str], deny :: List[Str], require_purpose :: Bool }

fn work_policy() -> Policy {
  { agent_pattern: "did:lex:agent:work-*", allow: ["preferences", "professional", "calendar"], deny: ["health", "financial"], require_purpose: true }
}

# An access request: who wants which scopes of whose profile, and why.
type Request = { request_id :: Str, agent_did :: Str, scopes :: List[Str], purpose :: Str }

fn requests() -> List[Request] {
  [{ request_id: "req_001", agent_did: "did:lex:agent:work-scheduler", scopes: ["preferences", "calendar"], purpose: "schedule meetings" }, { request_id: "req_002", agent_did: "did:lex:agent:work-scheduler", scopes: ["professional", "health"], purpose: "wellness check" }, { request_id: "req_003", agent_did: "did:lex:agent:ad-tracker", scopes: ["preferences"], purpose: "ad targeting" }, { request_id: "req_004", agent_did: "did:lex:agent:work-scheduler", scopes: ["calendar"], purpose: "" }]
}

fn list_has(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (a :: Bool, s :: Str) -> Bool {
    a or s == x
  })
}

fn permitted(p :: Policy, scope :: Str) -> Bool {
  list_has(p.allow, scope) and not list_has(p.deny, scope)
}

fn filter_permitted(p :: Policy, scopes :: List[Str]) -> List[Str] {
  list.fold(scopes, [], fn (acc :: List[Str], s :: Str) -> List[Str] {
    if permitted(p, s) {
      list.concat(acc, [s])
    } else {
      acc
    }
  })
}

# The decision: a grant of the permitted subset, or a denial with a reason.
type Decision = Grant(List[Str]) | Deny(Str)

fn decide(p :: Policy, r :: Request) -> Decision {
  if not pattern_match(p.agent_pattern, r.agent_did) {
    Deny("no policy applies to this agent")
  } else {
    if p.require_purpose and str.is_empty(r.purpose) {
      Deny("a stated purpose is required")
    } else {
      let granted := filter_permitted(p, r.scopes)
      if list.len(granted) == 0 {
        Deny("none of the requested scopes are permitted")
      } else {
        Grant(granted)
      }
    }
  }
}

# ── trail payloads (a2p concepts as hash-chained events) ─────────────────────
fn scopes_json(xs :: List[Str]) -> Str {
  str.join(["[", str.join(list.map(xs, fn (s :: Str) -> Str {
    str.join(["\"", s, "\""], "")
  }), ","), "]"], "")
}

fn policy_opened_json(p :: Policy) -> Str {
  str.join(["{\"agent_pattern\":\"", p.agent_pattern, "\",\"allow\":", scopes_json(p.allow), ",\"deny\":", scopes_json(p.deny), ",\"require_purpose\":", if p.require_purpose {
    "true"
  } else {
    "false"
  }, "}"], "")
}

fn requested_json(user :: Str, r :: Request) -> Str {
  str.join(["{\"request_id\":\"", r.request_id, "\",\"agent_did\":\"", r.agent_did, "\",\"user_did\":\"", user, "\",\"scopes\":", scopes_json(r.scopes), ",\"purpose\":\"", r.purpose, "\"}"], "")
}

fn granted_json(r :: Request, granted :: List[Str]) -> Str {
  str.join(["{\"request_id\":\"", r.request_id, "\",\"agent_did\":\"", r.agent_did, "\",\"granted\":", scopes_json(granted), "}"], "")
}

fn denied_json(r :: Request, reason :: Str) -> Str {
  str.join(["{\"request_id\":\"", r.request_id, "\",\"agent_did\":\"", r.agent_did, "\",\"reason\":\"", reason, "\"}"], "")
}

# Process one request through the gate, attesting the receipt to the trail.
fn handle(log :: trail.Log, p :: Policy, user :: Str, r :: Request) -> [io, sql, time] Int {
  let _req := trail.append(log, "consent.requested", None, requested_json(user, r))
  match decide(p, r) {
    Grant(granted) => {
      let _g := trail.append(log, "consent.granted", None, granted_json(r, granted))
      let _l := io.print(str.join(["  ✓ ", r.agent_did, " → GRANTED ", scopes_json(granted), "  (purpose: ", r.purpose, ")"], ""))
      1
    },
    Deny(reason) => {
      let _d := trail.append(log, "consent.denied", None, denied_json(r, reason))
      let _l := io.print(str.join(["  ✗ ", r.agent_did, " → DENIED ", scopes_json(r.scopes), "  — ", reason], ""))
      0
    },
  }
}

fn run() -> [io, sql, time, fs_write, env] Nil {
  let trail_path := match env.get("CONSENT_TRAIL") {
    Some(v) => v,
    None => "consent_trail.jsonl",
  }
  let user := did("user", "alice")
  let __lex_discard_1 := io.print(str.join(["=== Lex consent gate — ", user, " — receipts are verifiable, not just claimed ===\n"], ""))
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let p := work_policy()
      let _po := match trail.append(log, "policy.opened", None, policy_opened_json(p)) {
        Err(e) => io.print(str.concat("policy.opened write failed: ", e)),
        Ok(_) => io.print(str.join(["policy: agents ", p.agent_pattern, " may read ", scopes_json(p.allow), ", never ", scopes_json(p.deny), " (purpose required)\n"], "")),
      }
      let _walk := list.fold(requests(), 0, fn (n :: Int, r :: Request) -> [io, sql, time] Int {
        n + handle(log, p, user, r)
      })
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let _w := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event)))
          io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " consent-trail events → ", trail_path], ""))
        },
      }
    },
  }
}

