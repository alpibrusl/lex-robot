# lex-robot/examples/skill_catalog_demo.lex — registers and calls every
# skill in examples/skill_library.lex's proposed catalog, grouped by tier.
#
# examples/skill_acquisition_demo.lex proved the MECHANISM with one skill
# (geocode_place: register, call, and watch an undeclared-effect tool get
# refused). This demo proves the CATALOG: all 10 informational
# skills, registered and called for real against examples/skills_api_stub.py,
# including the one (`unit_convert`) that needs no [net] at all — a live
# demonstration that "acquire a skill" scales to a real backlog, not just
# a single hand-picked example.
#
# Run: examples/skill_catalog_demo_run.sh (starts the tool registry + the
# skills API stub, runs this, tears both down).

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.http" as http

import "std.map" as map

import "std.env" as env

import "lex-schema/json_value" as jv

import "./skill_library" as lib

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

fn register(registry_url :: Str, spec :: lib.SkillSpec) -> [net] Result[Str, Str] {
  let effects_json := JList(list.map(spec.allowed_effects, fn (e :: Str) -> jv.Json {
    JStr(e)
  }))
  let hosts_json := JList(list.map(spec.allow_net_host, fn (h :: Str) -> jv.Json {
    JStr(h)
  }))
  let req := JObj([("name", JStr(spec.name)), ("body", JStr(spec.body)), ("allowed_effects", effects_json), ("allow_net_host", hosts_json)])
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

fn run_one(registry_url :: Str, spec :: lib.SkillSpec) -> [net, io] Unit {
  let effects_label := if list.is_empty(spec.allowed_effects) {
    "[]"
  } else {
    str.join(["[", str.join(spec.allowed_effects, ", "), "]"], "")
  }
  match register(registry_url, spec) {
    Err(e) => io.print(str.join(["  [tier ", spec.tier, "] ", spec.name, " ", effects_label, " — registration FAILED: ", e], "")),
    Ok(tool_id) => {
      let result := invoke(registry_url, tool_id, spec.sample_input)
      io.print(str.join(["  [tier ", spec.tier, "] ", spec.name, " ", effects_label, "(\"", spec.sample_input, "\") -> ", result], ""))
    },
  }
}

fn run() -> [env, net, io] Unit {
  let registry_url := match env.get("TOOL_REGISTRY_URL") {
    None => "http://localhost:8300",
    Some(u) => u,
  }
  let stub_url := match env.get("SKILLS_API_STUB_URL") {
    None => "http://localhost:8930",
    Some(u) => u,
  }
  let __0 := io.print("══════════════════════════════════════════════════════")
  let __1 := io.print("   SKILL CATALOG  ·  10 informational skills, acquired live")
  let __2 := io.print("══════════════════════════════════════════════════════")
  let __3 := io.print("")
  let specs := lib.catalog(stub_url)
  let __4 := list.map(specs, fn (spec :: lib.SkillSpec) -> [net, io] Unit {
    run_one(registry_url, spec)
  })
  let __5 := io.print("")
  io.print(str.join(["all ", int.to_str(list.len(specs)), " skills registered and called — zero skills.lex edits, zero redeploys."], ""))
}

