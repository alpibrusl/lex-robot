# xlerobot_touch_demo — the 7-inch touchscreen as a GRANTED capability.
#
# The kiosk display (GET /display) gained its one input path: `show_prompt`
# puts a question with large tap targets on the robot's screen, a person taps,
# and `read_touch` hands the tapped option to the governed program. The two
# halves are SEPARATE skills on purpose: showing a question is an act on the
# world (like show_text), while reading the answer is a sense (like listen) —
# so a grant can allow asking without allowing hearing the answer, and either
# refusal is auditable.
#
# Three moments, in order:
#   1. read_touch BEFORE any prompt — honestly empty: a tap can only answer
#      something actually shown; there is nothing to read, canned or not.
#   2. The consent loop — prompt on the screen, tap comes back, program acts.
#   3. The refusal — a grant that may show prompts but not read taps: same
#      program, same sidecar, the read is never sent.
#
# Run it:  make xlerobot-touch   (or: bash scripts/demo.sh xlerobot_touch)
# The stub sidecar answers with a canned tap (default: the first option;
# override: LEX_XLE_TOUCH=no make xlerobot-touch). On hardware the same seam
# is a real finger on the panel — see docs/XLEROBOT_SETUP.md "Attaching a
# screen".

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "../src/types" as t

import "../src/skills" as sk

# The full touch envelope: may ask on the screen AND read the answer back.
fn touch_grant() -> t.Grant {
  { skills: ["show_prompt", "read_touch", "show_text", "clear_display"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 }
}

# The same envelope with the touch INPUT withheld: it may put questions on
# the screen, but the answers are not its to read.
fn ask_only_grant() -> t.Grant {
  { skills: ["show_prompt", "show_text", "clear_display"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 }
}

# Pull the "option" value out of the sidecar's touch JSON. Separator-agnostic,
# same shape as xlerobot_voice_demo's transcript_of.
fn option_of(json :: Str) -> Str {
  let parts := str.split(json, "\"option\"")
  match list.head(list.tail(parts)) {
    None => "",
    Some(rest) => match list.head(list.tail(str.split(rest, "\""))) {
      None => "",
      Some(opt) => opt,
    },
  }
}

fn run() -> [net, sense, actuate, io] Unit {
  let touching := { sidecar_url: "http://localhost:8900", grant: touch_grant() }
  let ask_only := { sidecar_url: "http://localhost:8900", grant: ask_only_grant() }
  let __1 := match sk.read_touch(touching) {
    Ok(resp) => if option_of(resp) == "" {
      io.print("before any prompt → no tap (nothing shown, nothing to answer)")
    } else {
      io.print("tap out of thin air — THIS MUST NOT HAPPEN")
    },
    Err(e) => io.print(str.concat("read_touch failed: ", e)),
  }
  let __2 := match sk.show_prompt(touching, "Fetch the cup from the kitchen?", ["yes", "no"]) {
    Reached => io.print("prompt on screen: Fetch the cup from the kitchen?  [yes] [no]"),
    Denied(d) => io.print(str.concat("show_prompt denied: ", d)),
    Stalled(s) => io.print(str.concat("show_prompt stalled: ", s)),
    Killed(k) => io.print(str.concat("show_prompt killed: ", k)),
    Timeout => io.print("show_prompt timed out"),
  }
  let __3 := match sk.read_touch(touching) {
    Ok(resp) => {
      let opt := option_of(resp)
      let __a := io.print(str.concat("tap: ", opt))
      if opt == "yes" {
        match sk.show_text(touching, "On it — fetching the cup.") {
          Reached => io.print("acknowledged on screen: On it — fetching the cup."),
          Denied(d) => io.print(str.concat("show_text denied: ", d)),
          Stalled(s) => io.print(str.concat("show_text stalled: ", s)),
          Killed(k) => io.print(str.concat("show_text killed: ", k)),
          Timeout => io.print("show_text timed out"),
        }
      } else {
        match sk.show_text(touching, "Understood — staying put.") {
          Reached => io.print("acknowledged on screen: Understood — staying put."),
          Denied(d) => io.print(str.concat("show_text denied: ", d)),
          Stalled(s) => io.print(str.concat("show_text stalled: ", s)),
          Killed(k) => io.print(str.concat("show_text killed: ", k)),
          Timeout => io.print("show_text timed out"),
        }
      }
    },
    Err(e) => io.print(str.concat("read_touch failed: ", e)),
  }
  let __4 := match sk.read_touch(ask_only) {
    Ok(_) => io.print("ask-only robot read a tap — THIS MUST NOT HAPPEN"),
    Err(e) => io.print(str.concat("ask-only robot → denied: ", e)),
  }
  let __5 := match sk.clear_display(touching) {
    Reached => io.print("display cleared"),
    Denied(d) => io.print(str.concat("clear_display denied: ", d)),
    Stalled(s) => io.print(str.concat("clear_display stalled: ", s)),
    Killed(k) => io.print(str.concat("clear_display killed: ", k)),
    Timeout => io.print("clear_display timed out"),
  }
  ()
}

