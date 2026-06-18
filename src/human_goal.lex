# src/human_goal.lex — reusable "human defines the goal" pattern.
#
# The reusable shape for EVERY demo: at the start of a run the agent asks the
# human operator for its goal through the dashboard, blocks until the human
# answers, then proceeds — so the goal is provided by a human, never hardcoded.
#
# It rides the same plumbing as human escalation (heist vault code, triage
# evacuation approval, …):
#   1. POST dash/ask-human {id, customer, question}  → dashboard shows a prompt
#   2. GET  dash/get-answer/<id>  (server blocks ~60s until the operator submits)
#   3. returns the operator's reply as a string for the agent to parse
#
# Demo-agnostic: any agent imports this and calls ask_goal() at startup.
# Effects: [net, io].

import "std.str"   as str
import "std.http"  as http
import "std.bytes" as bytes
import "std.map"   as map
import "std.io"    as io

# Minimal JSON string escaping (quotes + backslashes).
fn esc(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

# Ask the human operator for a goal and block until they answer.
# `customer` keys the question (one pending per customer); `prompt` is shown in
# the dashboard's question card. Returns the trimmed answer, or "" on timeout.
fn ask_goal(dash :: Str, customer :: Str, prompt :: Str) -> [net, io] Str {
  if str.is_empty(dash) { "" } else {
    let qid := str.concat("goal-", customer)
    let _ := io.print(str.join(["  [", customer, "] awaiting human goal: ", prompt], ""))
    let body := str.join(["{\"id\":\"", qid, "\",\"customer\":\"", customer, "\",\"question\":\"", esc(prompt), "\"}"], "")
    let post_req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(dash, "/ask-human"), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }, 5000), "Content-Type", "application/json")
    let _ := http.send(post_req)
    let poll_req := http.with_timeout_ms({ method: "GET", url: str.join([dash, "/get-answer/", qid], ""), headers: map.new(), body: None, timeout_ms: None }, 65000)
    match http.send(poll_req) {
      Err(_) => "",
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => "",
        Ok(answer) => {
          let a := str.trim(answer)
          let _ := io.print(str.join(["  [", customer, "] ← human goal: ", a], ""))
          a
        },
      },
    }
  }
}
