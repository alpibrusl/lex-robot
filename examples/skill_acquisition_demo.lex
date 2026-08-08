# lex-robot/examples/skill_acquisition_demo.lex — a robot acquires a new
# INFORMATIONAL skill at runtime, no source change, no redeploy.
#
# Follows on from the fleet-coordination work (epic #115): that epic asked
# "how do multiple robots share physical space safely" — this demo answers
# a different question raised alongside it: "if a planner needs a skill it
# doesn't have (e.g. resolving a place name to coordinates for a 'go to
# place X' goal), does the robot have to be re-coded and redeployed, or can
# it acquire the skill on request?"
#
# The answer lives in lex-lang's own toolchain, not in this repo: `lex
# agent-tool` has an LLM emit a Lex tool body that only ever runs under a
# declared, capped effect set (the type checker rejects anything the body
# does beyond it, before a byte executes); `lex tool-registry serve` puts
# that on a network — register once (POST /tools, effects declared up
# front, checked at registration), call many times (POST
# /tools/{id}/invoke) via a stable endpoint. No skills.lex edit, no PR.
#
# This demo hand-authors the tool body that `lex agent-tool --request "..."`
# would otherwise synthesize (no ANTHROPIC_API_KEY is assumed here — same
# "mock model" precedent xlerobot-llm-mock already sets for this repo's
# demos) and proves the mechanism for real: register, invoke a known place,
# invoke an unknown one, then try to sneak an undeclared effect into a
# SECOND registration and watch it get refused before it's ever runnable.
#
# The geocoding call itself hits a local STUB (geocode_stub.py) rather than
# the real https://nominatim.openstreetmap.org/search — this sandbox's
# egress policy blocks that host outright; the tool body is unchanged
# either way; a real deployment swaps one URL.
#
# WHY THIS STAYS AN INFORMATIONAL-SKILL DEMO, NOT A GENERAL ONE: the tool
# body here only ever needs `[net]`. A skill that needs `[actuate]` or
# `[sense]` — a new physical motion, a new sensor read — should NOT be
# self-service this way: the type checker guarantees a tool can't exceed
# its declared effects, it says nothing about whether an operator actually
# wants an LLM's own generated code driving a physical arm. That stays a
# reviewed grant-widening decision, not an on-demand registration.
#
# Run: examples/skill_acquisition_demo_run.sh (starts the tool registry +
# the geocoding stub, runs this, tears both down).

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.http" as http

import "std.map" as map

import "std.env" as env

import "lex-schema/json_value" as jv

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn post_json(url :: Str, body :: Str) -> [net] Result[Str, Str] {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 10000), "Content-Type", "application/json")
  match http.send(req) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match http.text_body(resp) {
      Err(e) => Err(http_err_str(e)),
      Ok(s) => Ok(s),
    },
  }
}

# The tool body a `--request "geocode a place name"` call would otherwise
# synthesize — hand-authored here (see module comment for why), but this
# exact string is what gets registered and run under the declared [net]
# effect, nothing more.
fn geocode_tool_body(stub_url :: Str) -> Str {
  str.join(["let q := str.replace(str.replace(input, \" \", \"+\"), \",\", \"%2C\")\n", "let url := str.join([\"", stub_url, "/search?format=json&limit=1&q=\", q], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(body) => {\n", "    let parsed :: Result[List[{ lat :: Str, lon :: Str, display_name :: Str }], Str] := json.parse(body)\n", "    match parsed {\n", "      Err(e) => str.join([\"parse error: \", e], \"\"),\n", "      Ok(results) => match list.head(results) {\n", "        None => str.join([\"no results for: \", input], \"\"),\n", "        Some(r) => str.join([\"lat=\", r.lat, \" lon=\", r.lon, \" (\", r.display_name, \")\"], \"\"),\n", "      },\n", "    }\n", "  },\n", "}\n"], "")
}

fn register(registry_url :: Str, name :: Str, body :: Str, allowed_effects :: List[Str], allow_net_host :: List[Str]) -> [net] Result[Str, Str] {
  let effects_json := JList(list.map(allowed_effects, fn (e :: Str) -> jv.Json {
    JStr(e)
  }))
  let hosts_json := JList(list.map(allow_net_host, fn (h :: Str) -> jv.Json {
    JStr(h)
  }))
  let req := JObj([("name", JStr(name)), ("body", JStr(body)), ("allowed_effects", effects_json), ("allow_net_host", hosts_json)])
  match post_json(str.concat(registry_url, "/tools"), jv.stringify(req)) {
    Err(e) => Err(e),
    Ok(resp) => match jv.parse(resp) {
      Err(p) => Err(p.message),
      Ok(j) => match jv.get_field(j, "id") {
        Some(idv) => match jv.as_str(idv) {
          Some(id) => Ok(id),
          None => Err(str.concat("registry did not return an id: ", resp)),
        },
        None => Err(str.concat("registration refused: ", resp)),
      },
    },
  }
}

fn invoke(registry_url :: Str, tool_id :: Str, input :: Str) -> [net] Str {
  let req := JObj([("input", JStr(input))])
  match post_json(str.join([registry_url, "/tools/", tool_id, "/invoke"], ""), jv.stringify(req)) {
    Err(e) => str.concat("call failed: ", e),
    Ok(resp) => match jv.parse(resp) {
      Err(_) => resp,
      Ok(j) => match jv.get_field(j, "output") {
        Some(ov) => match jv.as_str(ov) {
          Some(s) => s,
          None => resp,
        },
        None => resp,
      },
    },
  }
}

fn run() -> [env, net, io] Unit {
  let registry_url := match env.get("TOOL_REGISTRY_URL") {
    None => "http://localhost:8300",
    Some(u) => u,
  }
  let stub_url := match env.get("GEOCODE_STUB_URL") {
    None => "http://localhost:8930",
    Some(u) => u,
  }
  let __0 := io.print("══════════════════════════════════════════════════════")
  let __1 := io.print("   SKILL ACQUISITION  ·  a robot registers a new tool at runtime")
  let __2 := io.print("══════════════════════════════════════════════════════")
  let __3 := io.print("")
  let __4 := io.print("── acquiring: geocode_place, declared effects = [net] only ──")
  let reg := register(registry_url, "geocode_place", geocode_tool_body(stub_url), ["net"], ["localhost"])
  match reg {
    Err(e) => io.print(str.concat("registration FAILED: ", e)),
    Ok(tool_id) => {
      let __5 := io.print(str.join(["registered as ", tool_id, " — no skills.lex edit, no redeploy"], ""))
      let __6 := io.print("")
      let __7 := io.print("── calling it, same as any other skill from here on ──")
      let __8 := io.print(str.concat("  Eiffel Tower       -> ", invoke(registry_url, tool_id, "Eiffel Tower")))
      let __9 := io.print(str.concat("  Madrid, Spain      -> ", invoke(registry_url, tool_id, "Madrid, Spain")))
      io.print(str.concat("  Atlantis (unknown) -> ", invoke(registry_url, tool_id, "Atlantis")))
    },
  }
  let __10 := io.print("")
  let __11 := io.print("── proving the boundary: a tool that claims [net] but actually uses [io] ──")
  let sneaky_body := "let _ := io.print(\"leaking stdout\")\n\"done\""
  match register(registry_url, "sneaky", sneaky_body, ["net"], []) {
    Ok(tool_id) => io.print(str.concat("BUG: should have been refused, got id ", tool_id)),
    Err(e) => io.print(str.concat("refused at registration, before it was ever runnable: ", e)),
  }
}

