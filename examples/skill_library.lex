# lex-robot/examples/skill_library.lex — the catalog of informational
# skills proposed alongside the fleet-coordination work: candidate tool
# bodies for the "acquire a skill on request" mechanism
# examples/skill_acquisition_demo.lex proved with a single skill
# (geocode_place). This module is pure — it only builds tool-body TEXT and
# registration metadata; examples/skill_catalog_demo.lex is what actually
# registers and calls them.
#
# Every entry here declares `[net]` only, except `unit_convert`, which
# declares NO effects at all — a deliberate example that "acquire a skill"
# doesn't mean "always grant net": the effect wall is fewest-privileges,
# not a fixed ceiling. None of these ever declares `[actuate]`/`[sense]` —
# see skill_acquisition_demo.lex's module comment for why that boundary is
# load-bearing, not incidental.
#
# Each tool body is hand-authored here in place of a real `lex agent-tool
# --request "..."` synthesis (no ANTHROPIC_API_KEY assumed — same
# "mock model" precedent xlerobot-llm-mock sets elsewhere), and calls
# examples/skills_api_stub.py's matching endpoint — a stand-in for the
# real public API named in each function's comment. Swapping the stub's
# base URL for the real one is the only change a real deployment needs.

import "std.str" as str

type SkillSpec = { tier :: Str, name :: Str, body :: Str, allowed_effects :: List[Str], allow_net_host :: List[Str], sample_input :: Str }

# ── Tier 1: direct extensions of what's already in this repo's demos ──────
# Stand-in for https://nominatim.openstreetmap.org/search. Input: a place
# name. Ties into llm_planner's "go to place X" goals (see
# skill_acquisition_demo.lex, which registers this one skill on its own).
fn geocode_place(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let q := str.replace(str.replace(input, \" \", \"+\"), \",\", \"%2C\")\n", "let url := str.join([\"", stub_url, "/geocode/search?format=json&limit=1&q=\", q], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[List[{ lat :: Str, lon :: Str, display_name :: Str }], Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(e) => str.join([\"parse error: \", e], \"\"),\n", "      Ok(results) => match list.head(results) {\n", "        None => str.join([\"no results for: \", input], \"\"),\n", "        Some(r) => str.join([\"lat=\", r.lat, \" lon=\", r.lon, \" (\", r.display_name, \")\"], \"\"),\n", "      },\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "1", name: "geocode_place", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "Eiffel Tower" }
}

# Stand-in for a directions/distance-matrix API. Input: "<from>|<to>" (two
# place names already known to geocode_place). Answers "how far/how long"
# without ever claiming the robot can drive there — see the README's
# "Multi-robot coordination" section on why real navigation is out of
# scope for this codebase.
fn route_eta(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let parts := str.split(input, \"|\")\n", "let f := match list.head(parts) { Some(s) => s, None => \"\" }\n", "let t := match list.head(list.tail(parts)) { Some(s) => s, None => \"\" }\n", "let enc := fn (s :: Str) -> Str { str.replace(str.replace(s, \" \", \"+\"), \",\", \"%2C\") }\n", "let url := str.join([\"", stub_url, "/route/eta?from=\", enc(f), \"&to=\", enc(t)], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ distance_km :: Str, eta_min :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no route known between \", f, \" and \", t], \"\"),\n", "      Ok(r) => str.join([r.distance_km, \" km, \", r.eta_min, \" min\"], \"\"),\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "1", name: "route_eta", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "Eiffel Tower|Madrid, Spain" }
}

# Stand-in for a market-price API. Input: an item name. A reference price
# before a negotiation, not a binding action — feeds the bazaar/logistics
# demos' haggling, doesn't replace it.
fn fair_price_lookup(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let enc := str.replace(input, \" \", \"+\")\n", "let url := str.join([\"", stub_url, "/price/lookup?item=\", enc], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ item :: Str, currency :: Str, price :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no price known for: \", input], \"\"),\n", "      Ok(r) => str.join([r.price, \" \", r.currency], \"\"),\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "1", name: "fair_price_lookup", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "coffee" }
}

# ── Tier 2: general planner grounding, useful regardless of scenario ──────
# Stand-in for an FX-rate API. Input: "<amount>|<from>|<to>" (currency
# codes). The bazaar/logistics demos already move "credits"; a real
# deployment needs real currency.
fn currency_convert(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let parts := str.split(input, \"|\")\n", "let amount_s := match list.head(parts) { Some(s) => s, None => \"0\" }\n", "let from_c := match list.head(list.tail(parts)) { Some(s) => s, None => \"\" }\n", "let to_c := match list.head(list.tail(list.tail(parts))) { Some(s) => s, None => \"\" }\n", "let url := str.join([\"", stub_url, "/currency/rate?from=\", from_c, \"&to=\", to_c], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ rate :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no rate known for \", from_c, \" -> \", to_c], \"\"),\n", "      Ok(r) => match str.to_float(amount_s) {\n", "        None => \"invalid amount\",\n", "        Some(amount) => match str.to_float(r.rate) {\n", "          None => \"invalid rate\",\n", "          Some(rate) => str.join([float.to_str(amount * rate), \" \", to_c], \"\"),\n", "        },\n", "      },\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "2", name: "currency_convert", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "10|EUR|USD" }
}

# Stand-in for a weather API. Input: a place name. Gates whether an
# outdoor-adjacent task makes sense — the planner can decide differently,
# it never acts on this directly (no [actuate] anywhere near it).
fn weather_lookup(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let enc := str.replace(str.replace(input, \" \", \"+\"), \",\", \"%2C\")\n", "let url := str.join([\"", stub_url, "/weather?place=\", enc], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ place :: Str, condition :: Str, temp_c :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no weather known for: \", input], \"\"),\n", "      Ok(r) => str.join([r.condition, \", \", r.temp_c, \"C\"], \"\"),\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "2", name: "weather_lookup", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "Madrid, Spain" }
}

# Stand-in for a web-search API. Input: a question the LLM can't answer
# from its own weights alone. Purely informational — no side effects.
fn web_search(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let enc := str.replace(input, \" \", \"+\")\n", "let url := str.join([\"", stub_url, "/search?q=\", enc], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ query :: Str, snippet :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no result for: \", input], \"\"),\n", "      Ok(r) => r.snippet,\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "2", name: "web_search", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "boiling point of water" }
}

# Stand-in for a translation API. Input: "<text>|<lang>". Directly useful
# on the speak/listen path for a non-native-language household or bazaar
# counterpart.
fn translate_text(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let parts := str.split(input, \"|\")\n", "let text := match list.head(parts) { Some(s) => s, None => \"\" }\n", "let lang := match list.head(list.tail(parts)) { Some(s) => s, None => \"\" }\n", "let url := str.join([\"", stub_url, "/translate?text=\", str.replace(text, \" \", \"+\"), \"&to=\", lang], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ translated :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no translation for: \", text], \"\"),\n", "      Ok(r) => r.translated,\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "2", name: "translate_text", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "hello|es" }
}

# ── Tier 3: narrower, still net-only or pure, lower immediate priority ────
# Stand-in for a reverse-geocoding API. Input: "<lat>|<lon>". Complement to
# geocode_place — turn a coordinate back into a name for `speak`.
fn reverse_geocode(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let parts := str.split(input, \"|\")\n", "let lat := match list.head(parts) { Some(s) => s, None => \"\" }\n", "let lon := match list.head(list.tail(parts)) { Some(s) => s, None => \"\" }\n", "let url := str.join([\"", stub_url, "/geocode/reverse?lat=\", lat, \"&lon=\", lon], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ display_name :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no place known at \", lat, \",\", lon], \"\"),\n", "      Ok(r) => r.display_name,\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "3", name: "reverse_geocode", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "40.4168|-3.7038" }
}

# Stand-in for a calendar API. Input: a query like "today afternoon". A
# real constraint check for "clean the house before 5pm" instead of a
# hardcoded time.
fn calendar_lookup(stub_url :: Str) -> SkillSpec {
  let body := str.join(["let enc := str.replace(input, \" \", \"+\")\n", "let url := str.join([\"", stub_url, "/calendar/lookup?query=\", enc], \"\")\n", "match net.get(url) {\n", "  Err(e) => str.join([\"error: \", e], \"\"),\n", "  Ok(resp) => {\n", "    let parsed :: Result[{ busy :: Bool, note :: Str }, Str] := json.parse(resp)\n", "    match parsed {\n", "      Err(_) => str.join([\"no calendar data for: \", input], \"\"),\n", "      Ok(r) => str.join([if r.busy { \"busy - \" } else { \"free - \" }, r.note], \"\"),\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "3", name: "calendar_lookup", body: body, allowed_effects: ["net"], allow_net_host: ["localhost"], sample_input: "today afternoon" }
}

# PURE — no stub call, no effects declared at all. Input:
# "<value>|<from_unit>|<to_unit>". The deliberate odd one out in this
# catalog: not every acquired skill needs [net], and the registry proves
# that too (registering this with allowed_effects: [] still succeeds).
fn unit_convert() -> SkillSpec {
  let body := str.join(["let parts := str.split(input, \"|\")\n", "let value_s := match list.head(parts) { Some(s) => s, None => \"0\" }\n", "let from_u := match list.head(list.tail(parts)) { Some(s) => s, None => \"\" }\n", "let to_u := match list.head(list.tail(list.tail(parts))) { Some(s) => s, None => \"\" }\n", "match str.to_float(value_s) {\n", "  None => \"invalid value\",\n", "  Some(v) => {\n", "    let pair := str.join([from_u, \"->\", to_u], \"\")\n", "    match pair {\n", "      \"km->mi\" => str.join([float.to_str(v * 0.621371), \" mi\"], \"\"),\n", "      \"mi->km\" => str.join([float.to_str(v * 1.60934), \" km\"], \"\"),\n", "      \"kg->lb\" => str.join([float.to_str(v * 2.20462), \" lb\"], \"\"),\n", "      \"lb->kg\" => str.join([float.to_str(v * 0.453592), \" kg\"], \"\"),\n", "      \"c->f\" => str.join([float.to_str(v * 1.8 + 32.0), \" F\"], \"\"),\n", "      \"f->c\" => str.join([float.to_str((v - 32.0) / 1.8), \" C\"], \"\"),\n", "      _ => str.join([\"unsupported conversion: \", from_u, \" -> \", to_u], \"\"),\n", "    }\n", "  },\n", "}\n"], "")
  { tier: "3", name: "unit_convert", body: body, allowed_effects: [], allow_net_host: [], sample_input: "10|km|mi" }
}

fn catalog(stub_url :: Str) -> List[SkillSpec] {
  [geocode_place(stub_url), route_eta(stub_url), fair_price_lookup(stub_url), currency_convert(stub_url), weather_lookup(stub_url), web_search(stub_url), translate_text(stub_url), reverse_geocode(stub_url), calendar_lookup(stub_url), unit_convert()]
}

