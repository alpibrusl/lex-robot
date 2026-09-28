# lex-robot/judge.lex — a typed-judgment provider (Jev, Laya) as the planner.
#
# The same judgment/authority split as llm_planner.lex, with a different kind
# of brain: a System One model that picks ONE option from a list and returns a
# probability, instead of an LLM that writes tool calls. Three rules make it
# safe to put one in front of the arm:
#
#   1. Code builds the options; the model only picks WHICH. Each Candidate
#      carries its own target, computed by code (perception, taught waypoints),
#      because these models return a label, not a continuous command.
#   2. Only admissible candidates are offered. `offered` drops any candidate
#      whose skill the grant lacks or whose target the grant would refuse, so
#      the model is never shown an option the robot may not take — an injected
#      "sweep everything off the table" has nothing to pick. The skills layer
#      still re-checks every command (defence in depth).
#   3. Probability below the measured threshold is an ABSTAIN, not a "probably".
#      theta comes from sidecar/judge_calibrate.py on the task at hand; Jev on
#      lex-social was nearly always wrong between 0.5 and 0.9. An unreachable
#      or confused judge is NoJudge — the caller holds, never guesses.
#
# [net] only: this module can reach the judge sidecar and nothing else. It
# deliberately does not import sense.lex for its JSON helpers — importing a
# module brings in its effect row, and a judge has no business with [sense].

import "std.str" as str

import "std.float" as flt

import "std.list" as list

import "std.bytes" as bytes

import "std.http" as http

import "std.map" as map

import "./types" as t

import "./grant" as grant

# A thing the robot could do next. `skill` is the grant-level primitive that
# executes it ("" for no actuation: done, hold); `target` is where, if it moves.
type Candidate = { id :: Str, skill :: Str, target :: Option[t.Vec3], note :: Str }

# The gate's verdict on one judgment.
type Judged = Act(Str, Float) | Abstain(Str, Float) | NoJudge(Str)

# ── Admission: what the model may be shown ───────────────────────────────────

# Admissible = the grant would let it run: no-actuation options always; an
# actuating one only if its skill is granted and its target (if any) is inside
# the workspace and outside the keep-out box.
fn admissible(g :: t.Grant, c :: Candidate, ko_lo :: t.Vec3, ko_hi :: t.Vec3) -> Bool {
  if str.is_empty(c.skill) {
    true
  } else {
    if grant.skill_allowed(g, c.skill) {
      match c.target {
        None => true,
        Some(p) => grant.in_workspace(g, p) and not grant.in_box(p, ko_lo, ko_hi),
      }
    } else {
      false
    }
  }
}

fn offered(g :: t.Grant, cs :: List[Candidate], ko_lo :: t.Vec3, ko_hi :: t.Vec3) -> List[Candidate] {
  list.filter(cs, fn (c :: Candidate) -> Bool { admissible(g, c, ko_lo, ko_hi) })
}

fn withheld(g :: t.Grant, cs :: List[Candidate], ko_lo :: t.Vec3, ko_hi :: t.Vec3) -> List[Str] {
  list.map(list.filter(cs, fn (c :: Candidate) -> Bool { not admissible(g, c, ko_lo, ko_hi) }),
    fn (c :: Candidate) -> Str { c.id })
}

fn ids(cs :: List[Candidate]) -> List[Str] {
  list.map(cs, fn (c :: Candidate) -> Str { c.id })
}

fn find(cs :: List[Candidate], id :: Str) -> Option[Candidate] {
  list.fold(cs, None, fn (acc :: Option[Candidate], c :: Candidate) -> Option[Candidate] {
    match acc {
      Some(_) => acc,
      None => if c.id == id { Some(c) } else { None },
    }
  })
}

fn has(xs :: List[Str], x :: Str) -> Bool
  examples {
    has(["a", "b"], "b") => true,
    has(["a", "b"], "c") => false,
    has([], "a") => false
  }
{
  list.fold(xs, false, fn (acc :: Bool, s :: Str) -> Bool { acc or s == x })
}

# ── The gate ─────────────────────────────────────────────────────────────────

# A reply becomes an action only when the judge answered, chose something that
# was offered, and is at least theta sure. Everything else is not an action.
fn gate(ok :: Bool, choice :: Str, p :: Float, offered_ids :: List[Str], theta :: Float) -> Judged
  examples {
    gate(true, "grasp_cup", 0.97, ["grasp_cup", "hold"], 0.9) => Act("grasp_cup", 0.97),
    gate(true, "grasp_cup", 0.9, ["grasp_cup", "hold"], 0.9) => Act("grasp_cup", 0.9),
    gate(true, "grasp_cup", 0.62, ["grasp_cup", "hold"], 0.9) => Abstain("grasp_cup", 0.62),
    gate(true, "sweep_table", 0.99, ["grasp_cup", "hold"], 0.9) => NoJudge("judge chose sweep_table, which was not offered"),
    gate(false, "", 0.0, ["grasp_cup"], 0.9) => NoJudge("judge gave no answer")
  }
{
  if not ok {
    NoJudge("judge gave no answer")
  } else {
    if not has(offered_ids, choice) {
      NoJudge(str.join(["judge chose ", choice, ", which was not offered"], ""))
    } else {
      if p >= theta { Act(choice, p) } else { Abstain(choice, p) }
    }
  }
}

# ── Wire ─────────────────────────────────────────────────────────────────────

fn after(json :: Str, key :: Str) -> Str {
  match list.head(list.tail(str.split(json, key))) {
    Some(v) => str.trim(v),
    None => "",
  }
}

# The sidecar answers with Python json.dumps (", " / ": " spacing).
fn reply_str(json :: Str, key :: Str) -> Str
  examples {
    reply_str("{\"ok\": true, \"choice\": \"grasp_cup\", \"p\": 0.93}", "\"choice\":") => "grasp_cup",
    reply_str("{\"ok\": false}", "\"choice\":") => ""
  }
{
  match list.head(list.tail(str.split(after(json, key), "\""))) {
    Some(v) => v,
    None => "",
  }
}

fn reply_float(json :: Str, key :: Str) -> Float
  examples {
    reply_float("{\"ok\": true, \"p\": 0.93, \"probabilities\": {}}", "\"p\":") => 0.93,
    reply_float("{\"ok\": false}", "\"p\":") => 0.0
  }
{
  let seg := after(json, key)
  let tok := match list.head(str.split(seg, ",")) {
    Some(v) => v,
    None => seg,
  }
  let tok2 := match list.head(str.split(tok, "}")) {
    Some(v) => v,
    None => tok,
  }
  match str.to_float(str.trim(tok2)) {
    Some(v) => v,
    None => 0.0,
  }
}

fn parse_reply(resp :: Str, offered_ids :: List[Str], theta :: Float) -> Judged
  examples {
    parse_reply("{\"ok\": true, \"choice\": \"hold\", \"p\": 0.96}", ["hold", "grasp_cup"], 0.9) => Act("hold", 0.96),
    parse_reply("{\"ok\": true, \"choice\": \"hold\", \"p\": 0.5}", ["hold", "grasp_cup"], 0.9) => Abstain("hold", 0.5),
    parse_reply("{\"ok\": false, \"error\": \"jev HTTP 503\"}", ["hold"], 0.9) => NoJudge("jev HTTP 503")
  }
{
  let ok := str.contains(resp, "\"ok\": true") or str.contains(resp, "\"ok\":true")
  if ok {
    gate(true, reply_str(resp, "\"choice\":"), reply_float(resp, "\"p\":"), offered_ids, theta)
  } else {
    let e := reply_str(resp, "\"error\":")
    NoJudge(if str.is_empty(e) { "judge gave no answer" } else { e })
  }
}

fn esc(s :: Str) -> Str {
  str.replace(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\n", " ")
}

fn options_json(cs :: List[Candidate]) -> Str
  examples {
    options_json([{ id: "hold", skill: "", target: None, note: "person near the arm: no" }]) => "[{\"id\":\"hold\",\"note\":\"person near the arm: no\"}]"
  }
{
  let items := list.map(cs, fn (c :: Candidate) -> Str {
    str.join(["{\"id\":\"", esc(c.id), "\",\"note\":\"", esc(c.note), "\"}"], "")
  })
  str.join(["[", str.join(items, ","), "]"], "")
}

fn request_json(task :: Str, facts_json :: Str, cs :: List[Candidate]) -> Str {
  str.join(["{\"task\":\"", esc(task), "\",\"facts\":", facts_json, ",\"options\":", options_json(cs), "}"], "")
}

# Ask the judge which offered option to run. Only admitted candidates may be
# passed here — call `offered` first. Returns the raw reply for the trail.
fn ask_raw(judge_url :: Str, task :: Str, facts_json :: Str, cs :: List[Candidate]) -> [net] Result[Str, Str] {
  let url := str.concat(judge_url, "/judge/next_skill")
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(request_json(task, facts_json, cs))), timeout_ms: None }
  let req := http.with_timeout_ms(http.with_header(req0, "Content-Type", "application/json"), 5000)
  match http.send(req) {
    Err(_) => Err("judge unreachable"),
    Ok(resp) => match http.text_body(resp) {
      Err(_) => Err("judge reply undecodable"),
      Ok(s) => Ok(s),
    },
  }
}

fn ask(judge_url :: Str, task :: Str, facts_json :: Str, cs :: List[Candidate], theta :: Float) -> [net] Judged {
  match ask_raw(judge_url, task, facts_json, cs) {
    Err(e) => NoJudge(e),
    Ok(resp) => parse_reply(resp, ids(cs), theta),
  }
}

fn describe(j :: Judged) -> Str {
  match j {
    Act(c, p) => str.join(["act ", c, " (p=", flt.to_str(p), ")"], ""),
    Abstain(c, p) => str.join(["abstain — leaned ", c, " at p=", flt.to_str(p), ", below threshold"], ""),
    NoJudge(e) => str.concat("no judgment — ", e),
  }
}
