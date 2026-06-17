# examples/bazaar_interactive.lex — single customer dispatched from the dashboard.
#
# Launched by the sidecar's POST /add-customer endpoint.
# Configuration comes from environment variables:
#
#   CUSTOMER_NAME       — display name (default: Guest)
#   CUSTOMER_GOAL       — free-form goal (default: "Find a Bowl for at most 15 credits")
#   CUSTOMER_ASK_HUMAN  — "1" to enable ask_human tool (default: off)
#
#   Per-stall toggles (set to "0" to exclude; default: all enabled):
#   STALL_POTTERY  STALL_CLAY  STALL_TEXTILE  STALL_FABRIC  STALL_SPICES  STALL_HERB
#
# Stall setup order: pottery, clay, textile, fabric, spices, herb (enabled ones only).

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "lex-trail/src/log" as tlog

import "lex-llm/src/providers/vertex" as vtx

import "../src/a2a_card" as card

import "../src/bazaar" as baz

import "./bazaar_rush" as rush

# ── Conditional stall setup ───────────────────────────────────────────────────
# Returns Some(stall) if use=true and setup succeeds, None otherwise.
fn maybe_stall(use :: Bool, url :: Str, name :: Str, secret :: Bytes) -> [net, io] Option[baz.StallInfo] {
  if use {
    match rush.setup_one(url, name, secret) {
      Err(e) => { let _p := io.print(str.concat("[interactive] stall error: ", e)); None },
      Ok(s) => Some(s),
    }
  } else {
    None
  }
}

fn bool_env(key :: Str, default_on :: Bool) -> [env] Bool {
  match env.get(key) {
    Some("0") => false,
    Some("1") => true,
    _ => default_on,
  }
}

fn run() -> [net, io, sql, fs_write, sense, time, env, llm, proc] Unit {
  let name := match env.get("CUSTOMER_NAME") {
    None => "Guest",
    Some(v) => if str.is_empty(v) { "Guest" } else { v },
  }
  let goal := match env.get("CUSTOMER_GOAL") {
    None => "Find a Bowl for at most 15 credits",
    Some(v) => if str.is_empty(v) { "Find a Bowl for at most 15 credits" } else { v },
  }
  let ask_human_enabled := bool_env("CUSTOMER_ASK_HUMAN", false)

  # Per-stall toggles — default ON for all
  let use_pottery := bool_env("STALL_POTTERY", true)
  let use_clay    := bool_env("STALL_CLAY",    true)
  let use_textile := bool_env("STALL_TEXTILE", true)
  let use_fabric  := bool_env("STALL_FABRIC",  true)
  let use_spices  := bool_env("STALL_SPICES",  true)
  let use_herb    := bool_env("STALL_HERB",    true)

  let dash := "http://localhost:8900"
  let trail_path := str.concat("/tmp/lex-interactive-", str.concat(name, ".db"))

  let vertex_token    := match env.get("VERTEX_ACCESS_TOKEN") { None => "", Some(v) => v }
  let vertex_project  := match env.get("VERTEX_PROJECT")      { None => "", Some(v) => v }
  let vertex_location := match env.get("VERTEX_LOCATION")     { None => "eu", Some(v) => if str.is_empty(v) { "eu" } else { v } }
  let provider := vtx.make_provider(vtx.config_at(vertex_token, vertex_project, vertex_location))
  let model    := vtx.gemini_35_flash()

  let ask_tag := if ask_human_enabled { " (ask_human ON)" } else { "" }
  let _pi := io.print(str.join(["[", name, "] dispatched — goal: \"", goal, "\"", ask_tag], ""))

  match tlog.open(trail_path) {
    Err(e) => io.print(str.concat("[interactive] trail: ", e)),
    Ok(log) => {
      match tlog.append(log, "interactive_start", None, "{}") {
        Err(e) => io.print(str.concat("[interactive] trail root: ", e)),
        Ok(root) => {
          let now    := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 60000 }

          # Set up enabled stalls in visit order
          let stall_opts := [
            maybe_stall(use_pottery, "http://localhost:8901", "Pottery Palace", rush.pottery_secret()),
            maybe_stall(use_clay,    "http://localhost:8904", "Clay Corner",    rush.clay_secret()),
            maybe_stall(use_textile, "http://localhost:8902", "Textile Traders", rush.textile_secret()),
            maybe_stall(use_fabric,  "http://localhost:8905", "Fabric House",   rush.fabric_secret()),
            maybe_stall(use_spices,  "http://localhost:8903", "Spice Garden",   rush.spices_secret()),
            maybe_stall(use_herb,    "http://localhost:8906", "Herb Garden",    rush.herb_secret()),
          ]
          let stalls := list.fold(stall_opts, [], fn (acc :: List[baz.StallInfo], opt :: Option[baz.StallInfo]) -> List[baz.StallInfo] {
            match opt { None => acc, Some(s) => list.concat(acc, [s]) }
          })

          rush.shop_customer(name, goal, stalls, policy, log, root.id, now, provider, model, dash, ask_human_enabled)
        },
      }
    },
  }
}
