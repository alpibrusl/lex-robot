# examples/tinder.lex — agent matchmaking by mutual consent (A2A double opt-in).
#
# Each agent has a PUBLIC profile (name + interests — open to all) and a PRIVATE
# card (contact + a note — Ed25519-signed, revealed to NO ONE by default). For
# every pair, each agent decides independently whether it likes the other's
# public profile. A MATCH happens only when BOTH consent (double opt-in) — and
# only then are the signed private cards exchanged (selective disclosure).
#
# This is the A2A two-tier card model as matchmaking: public card = public
# profile, extended card = private details gated behind mutual consent.
#
# Env: TINDER_DASH_URL (default http://localhost:8900)
# Run via examples/tinder_run.sh

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time
import "std.crypto" as crypto

import "../src/a2a_card" as card

# ── helpers ──────────────────────────────────────────────────────────────────
fn json_str(s :: Str) -> Str {
  str.concat("\"", str.concat(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""))
}
fn notify(dash :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash) { () } else {
    let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}
fn str_list_json(xs :: List[Str]) -> Str {
  str.join(["[", str.join(list.map(xs, fn (s :: Str) -> Str { json_str(s) }), ","), "]"], "")
}
fn member(xs :: List[Str], v :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool { acc or x == v })
}

# ── Model ────────────────────────────────────────────────────────────────────
type Profile = { name :: Str, interests :: List[Str], seeks :: List[Str], contact :: Str, note :: Str, seed :: Str }

fn profiles() -> List[Profile] {
  [
    { name: "Ada", interests: ["art", "hiking"],     seeks: ["music"],  contact: "ada@six.net",  note: "loves gallery nights", seed: "tinder-seed-ada-000000000000000" },
    { name: "Bo",  interests: ["music"],             seeks: ["art"],    contact: "bo@six.net",   note: "plays jazz piano",     seed: "tinder-seed-bo-0000000000000000" },
    { name: "Cy",  interests: ["gaming", "music"],   seeks: ["art"],    contact: "cy@six.net",   note: "speedruns on weekends",seed: "tinder-seed-cy-0000000000000000" },
    { name: "Dee", interests: ["hiking"],            seeks: ["gaming"], contact: "dee@six.net",  note: "summited 12 peaks",    seed: "tinder-seed-dee-000000000000000" },
  ]
}

fn find(ps :: List[Profile], name :: Str) -> Option[Profile] {
  list.fold(ps, None, fn (acc :: Option[Profile], p :: Profile) -> Option[Profile] {
    match acc { Some(_) => acc, None => if p.name == name { Some(p) } else { None } }
  })
}

# A likes B iff B has an interest that A is seeking (decision on B's PUBLIC card).
fn likes(seeker :: Profile, target :: Profile) -> Bool {
  list.fold(target.interests, false, fn (acc :: Bool, it :: Str) -> Bool { acc or member(seeker.seeks, it) })
}

# Ed25519-signed private card (revealed only on match). Returns base64 signature.
fn sign_private(p :: Profile) -> Str {
  let priv_json := str.join(["{\"contact\":", json_str(p.contact), ",\"note\":", json_str(p.note), "}"], "")
  match card.sign_card(priv_json, bytes.from_str(str.slice(str.concat(p.seed, "00000000000000000000000000000000"), 0, 32))) {
    Ok(sig) => sig,
    Err(_)  => "",
  }
}

# ── Evaluate one pair: two consent decisions; reveal only on mutual yes ──────
fn match_pair(ps :: List[Profile], an :: Str, bn :: Str, dash :: Str) -> [net, io, crypto] Unit {
  match find(ps, an) {
    None => (),
    Some(a) => match find(ps, bn) {
      None => (),
      Some(b) => {
        let a_likes := likes(a, b)
        let b_likes := likes(b, a)
        let _ := io.print(str.join(["  ", a.name, " ", (if a_likes { "♥" } else { "✗" }), " ", b.name, "    ", b.name, " ", (if b_likes { "♥" } else { "✗" }), " ", a.name], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"swipe\",\"from\":\"", a.name, "\",\"to\":\"", b.name, "\",\"like\":", (if a_likes { "true" } else { "false" }), "}"], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"swipe\",\"from\":\"", b.name, "\",\"to\":\"", a.name, "\",\"like\":", (if b_likes { "true" } else { "false" }), "}"], ""))
        if a_likes and b_likes {
          # Mutual consent → match → exchange signed private cards (selective disclosure).
          let a_sig := sign_private(a)
          let b_sig := sign_private(b)
          let _ := io.print(str.join(["  ✔ MATCH ", a.name, " ✚ ", b.name, " — private cards unlocked"], ""))
          let _ := notify(dash, str.join(["{\"kind\":\"match\",\"a\":\"", a.name, "\",\"b\":\"", b.name, "\"}"], ""))
          let _ := notify(dash, str.join(["{\"kind\":\"reveal\",\"a\":\"", a.name, "\",\"a_contact\":", json_str(a.contact), ",\"a_note\":", json_str(a.note), ",\"a_sig\":", json_str(str.slice(a_sig, 0, 12)), ",\"b\":\"", b.name, "\",\"b_contact\":", json_str(b.contact), ",\"b_note\":", json_str(b.note), ",\"b_sig\":", json_str(str.slice(b_sig, 0, 12)), "}"], ""))
          ()
        } else {
          let _ := io.print(str.join(["  · no match (", a.name, "/", b.name, ") — private stays hidden"], ""))
          let _ := notify(dash, str.join(["{\"kind\":\"no_match\",\"a\":\"", a.name, "\",\"b\":\"", b.name, "\",\"one_sided\":", (if a_likes or b_likes { "true" } else { "false" }), "}"], ""))
          ()
        }
      },
    },
  }
}

# ── Entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, net, io, time, crypto] Unit {
  let dash := match env.get("TINDER_DASH_URL") { None => "http://localhost:8900", Some(u) => u }
  let ps := profiles()

  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   TINDER  ·  agent matchmaking by mutual consent (A2A double opt-in)")
  let _ := io.print("══════════════════════════════════════════════════════")

  # Publish public profiles (open cards). Private cards are NOT shared.
  let agents_json := str.join(list.map(ps, fn (p :: Profile) -> Str {
    str.join(["{\"name\":\"", p.name, "\",\"interests\":", str_list_json(p.interests), ",\"seeks\":", str_list_json(p.seeks), "}"], "")
  }), ",")
  let _ := notify(dash, str.join(["{\"kind\":\"tinder_start\",\"agents\":[", agents_json, "]}"], ""))

  # Evaluate a set of pairs. A match requires BOTH to consent.
  let pairs := [("Ada", "Bo"), ("Ada", "Cy"), ("Cy", "Dee"), ("Bo", "Dee")]
  let _ := list.fold(pairs, (), fn (_ :: Unit, pr :: (Str, Str)) -> [net, io, crypto] Unit {
    match pr { (an, bn) => match_pair(ps, an, bn, dash) }
  })

  let _ := notify(dash, "{\"kind\":\"done\",\"result\":\"matchmaking complete\"}")
  io.print("══════════════════════════════════════════════════════")
}
