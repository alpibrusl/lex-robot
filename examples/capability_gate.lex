# examples/capability_gate.lex — one capability token, governing data AND money.
#
# The platform kernel's control plane. Until now an agent's authority lived in two
# separate gates: lex-guard's spend gate (what it may PAY) and the consent gate
# (what it may KNOW). This unifies them into ONE signed capability — a single
# policy, held by one agent, that bounds BOTH — and records a mixed session (data
# reads + purchases) to ONE hash-chained trail. The same did:lex agent reads
# scopes and spends credits under the same token; over-scope reads and over-cap
# spends are both refused by the gate, and the whole session replays through one
# verifier (lex-games' `capability`).
#
# It composes the real pieces: the consent decision for reads, lex-guard's
# `gate.spend` + x402 (mock) for purchases — same trail, same policy snapshot.
#
# Env: CAP_TRAIL (trail output, default capability_trail.jsonl)
# Run: lex run --allow-effects io,sql,time,net,crypto,fs_write,env examples/capability_gate.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-guard/src/models" as models

import "lex-guard/src/gate" as gate

import "lex-guard/src/x402_mock_exec" as x402m

import "lex-games/src/arena/trail_file" as tf

# ── one capability: data authority + spend authority in a single policy ──────
type Cap = { agent_pattern :: Str, data_allow :: List[Str], data_deny :: List[Str], require_purpose :: Bool, spend_cap_total :: Int, spend_per_tx :: Int, merchants_allow :: List[Str] }

fn assistant_cap() -> Cap {
  { agent_pattern: "did:lex:agent:*", data_allow: ["preferences", "professional", "calendar"], data_deny: ["health", "financial"], require_purpose: true, spend_cap_total: 3000, spend_per_tx: 2000, merchants_allow: ["pottery.bazaar", "data.bazaar"] }
}

fn did(actor :: Str, id :: Str) -> Str {
  str.join(["did:lex:", actor, ":", id], "")
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "AssistantSoLAddr8888888888888888888888888888" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
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

fn scopes_json(xs :: List[Str]) -> Str {
  str.join(["[", str.join(list.map(xs, fn (s :: Str) -> Str {
    str.join(["\"", s, "\""], "")
  }), ","), "]"], "")
}

# One unified policy.opened carrying BOTH authorities — the verifier reads it once.
fn cap_opened_json(c :: Cap) -> Str {
  str.join(["{\"agent_pattern\":\"", c.agent_pattern, "\",\"data_allow\":", scopes_json(c.data_allow), ",\"data_deny\":", scopes_json(c.data_deny), ",\"require_purpose\":", if c.require_purpose {
    "true"
  } else {
    "false"
  }, ",\"spend_cap_total\":", int.to_str(c.spend_cap_total), ",\"spend_per_tx\":", int.to_str(c.spend_per_tx), ",\"merchants_allow\":", scopes_json(c.merchants_allow), "}"], "")
}

# ── the data leg (consent) ───────────────────────────────────────────────────
fn permitted(c :: Cap, scope :: Str) -> Bool {
  list_has(c.data_allow, scope) and not list_has(c.data_deny, scope)
}

fn filter_permitted(c :: Cap, scopes :: List[Str]) -> List[Str] {
  list.fold(scopes, [], fn (acc :: List[Str], s :: Str) -> List[Str] {
    if permitted(c, s) {
      list.concat(acc, [s])
    } else {
      acc
    }
  })
}

fn read_req(log :: trail.Log, c :: Cap, agent :: Str, scopes :: List[Str], purpose :: Str) -> [io, sql, time] Int {
  let _r := trail.append(log, "consent.requested", None, str.join(["{\"agent_did\":\"", agent, "\",\"scopes\":", scopes_json(scopes), ",\"purpose\":\"", purpose, "\"}"], ""))
  let ok_agent := pattern_match(c.agent_pattern, agent)
  let ok_purpose := not c.require_purpose or not str.is_empty(purpose)
  let granted := if ok_agent and ok_purpose {
    filter_permitted(c, scopes)
  } else {
    []
  }
  if list.len(granted) > 0 {
    let _g := trail.append(log, "consent.granted", None, str.join(["{\"agent_did\":\"", agent, "\",\"granted\":", scopes_json(granted), "}"], ""))
    let _l := io.print(str.join(["  📖 read ", scopes_json(scopes), " → GRANTED ", scopes_json(granted)], ""))
    1
  } else {
    let reason := if not ok_agent {
      "agent not covered by token"
    } else {
      if not ok_purpose {
        "purpose required"
      } else {
        "scopes not permitted"
      }
    }
    let _d := trail.append(log, "consent.denied", None, str.join(["{\"agent_did\":\"", agent, "\",\"reason\":\"", reason, "\"}"], ""))
    let _l := io.print(str.join(["  📖 read ", scopes_json(scopes), " → DENIED — ", reason], ""))
    0
  }
}

# ── the money leg (the real lex-guard spend gate, under the same Cap) ─────────
fn spend_policy(c :: Cap, agent :: Str) -> models.Policy {
  { token_id: "tok_cap", agent_id: agent, currency: "USDC", cap_total: c.spend_cap_total, cap_per_day: c.spend_cap_total, cap_per_transaction: c.spend_per_tx, merchants_allow: c.merchants_allow, categories_allow: ["goods", "saas"], max_tx_per_hour: 99, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn spend_req(log :: trail.Log, c :: Cap, agent :: Str, merchant :: Str, pay_to :: Str, amount :: Int) -> [io, sql, time, net, crypto] Int {
  let exec := x402m.make(signer(), pay_to, usdc_mint())
  let intent := { merchant: merchant, amount: amount, currency: "USDC", category: "goods", memo: "purchase" }
  match gate.spend(spend_policy(c, agent), log, exec, intent) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("  gate error: ", e))
      0
    },
    Ok(o) => if o.approved {
      let _l := io.print(str.join(["  💳 spend ", int.to_str(amount), " → ", merchant, " — SETTLED"], ""))
      1
    } else {
      let _l := io.print(str.join(["  💳 spend ", int.to_str(amount), " → ", merchant, " — DENIED (over cap / merchant not allowed)"], ""))
      0
    },
  }
}

fn run() -> [io, sql, time, net, crypto, fs_write, env] Nil {
  let trail_path := match env.get("CAP_TRAIL") {
    Some(v) => v,
    None => "capability_trail.jsonl",
  }
  let c := assistant_cap()
  let agent := match env.get("AGENT_DID") {
    Some(v) => v,
    None => did("agent", "assistant-1"),
  }
  let __lex_discard_2 := io.print(str.join(["=== Lex capability gate — one token for ", agent, ": data AND money ===\n"], ""))
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let _po := match trail.append(log, "policy.opened", None, cap_opened_json(c)) {
        Err(e) => io.print(str.concat("policy.opened write failed: ", e)),
        Ok(_) => io.print(str.join(["token: data ", scopes_json(c.data_allow), " (never ", scopes_json(c.data_deny), "); spend ≤", int.to_str(c.spend_per_tx), "/tx, ≤", int.to_str(c.spend_cap_total), " total, to ", scopes_json(c.merchants_allow), "\n"], "")),
      }
      let _1 := read_req(log, c, agent, ["preferences", "calendar"], "plan the week")
      let _2 := spend_req(log, c, agent, "pottery.bazaar", "PotterySoLAddr11111111111111111111111111111", 1800)
      let _3 := read_req(log, c, agent, ["financial"], "budgeting")
      let _4 := spend_req(log, c, agent, "gold.bazaar", "GoldSoLAddr6666666666666666666666666666666666", 5000)
      let _5 := spend_req(log, c, agent, "data.bazaar", "DataSoLAddr444444444444444444444444444444444", 1200)
      let _6 := read_req(log, c, agent, ["professional"], "")
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let _w := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event)))
          io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " capability-trail events → ", trail_path], ""))
        },
      }
    },
  }
}

