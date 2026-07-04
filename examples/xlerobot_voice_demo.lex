# xlerobot_voice_demo — the mic and camera as GRANTED capabilities.
#
# The XLeRobot 0.4.0 carries a head camera and a microphone — the two most
# privacy-sensitive sensors on the robot. Here they are governed the same way
# actuation is: `listen` and `read_camera` are [sense]-typed skills that must
# be NAMED IN THE GRANT, so "can this program hear the room?" is a typed,
# auditable, refusable question — not an ambient permission.
#
# The demo also closes the human_goal loop by voice: the run's goal comes from
# a person SPEAKING to the robot at run time (the sidecar transcribes locally —
# raw audio never crosses into Lex; only the transcript does). A second robot
# handle carrying a mic-less grant then shows the refusal: same program, same
# sidecar, no listen authority → denied at the capability layer, never sent.
#
# Run it:  make xlerobot-voice   (or: bash scripts/demo.sh xlerobot_voice)
# The stub sidecar answers with a canned transcript (override:
# LEX_XLE_TRANSCRIPT="wash the dishes" make xlerobot-voice); on hardware the
# seam becomes mic capture + local Whisper. The MuJoCo tier additionally
# renders the head camera offscreen (real pixels on hosts with a GL backend).

import "std.io"   as io
import "std.str"  as str
import "std.list" as list

import "../src/types"  as t
import "../src/sense" as sense

# Sensors-only grant: the mic and cameras, no actuation at all. Workspace and
# force fields are irrelevant for a sensing envelope — zeroed.
fn sensor_grant() -> t.Grant {
  { skills: ["listen", "read_camera", "read_base"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 },
    max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0,
    budget_actions: 10, budget_wall_ms: 60000 }
}

# The same envelope with the microphone WITHHELD — the owner muted the robot.
fn muted_grant() -> t.Grant {
  { skills: ["read_camera", "read_base"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 },
    max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0,
    budget_actions: 10, budget_wall_ms: 60000 }
}

# Pull the "transcript" value out of the sidecar's transcription JSON.
# Separator-agnostic: splits on the key, then takes the first quoted string
# after it (handles both {"transcript":"x"} and {"transcript": "x"}).
fn transcript_of(json :: Str) -> Str {
  let parts := str.split(json, "\"transcript\"")
  match list.head(list.tail(parts)) {
    None => "",
    Some(rest) => match list.head(list.tail(str.split(rest, "\""))) {
      None => "",
      Some(tr) => tr,
    },
  }
}

fn run() -> [net, sense, io] Unit {
  let hearing := { sidecar_url: "http://localhost:8900", grant: sensor_grant() }
  let muted := { sidecar_url: "http://localhost:8900", grant: muted_grant() }

  # 1. The goal arrives by VOICE — the human_goal pattern, spoken. The trail-
  #    safe transcript (never raw audio) is what authority derives from.
  let __1 := match sense.listen(hearing, 3) {
    Ok(resp) => io.print(str.concat("voice goal: ", transcript_of(resp))),
    Err(e) => io.print(str.concat("listen failed: ", e)),
  }

  # 2. The head camera under the same grant — frame metadata (the stub returns
  #    a placeholder frame; the MuJoCo tier renders the scene when GL exists).
  let __2 := match sense.read_camera(hearing, "head") {
    Ok(f) => io.print(str.concat("head camera frame: ", f)),
    Err(e) => io.print(str.concat("camera failed: ", e)),
  }

  # 3. The muted robot: same program, same sidecar — no listen authority.
  #    Refused at the capability layer; the request is NEVER SENT.
  let __3 := match sense.listen(muted, 3) {
    Ok(_) => io.print("muted robot heard something — THIS MUST NOT HAPPEN"),
    Err(e) => io.print(str.concat("muted robot → denied: ", e)),
  }
  ()
}
