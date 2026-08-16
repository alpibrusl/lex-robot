# vision_split_demo — the Pi drives, a GPU box sees.
#
# The split-compute vision path (deploy/VISION_SPLIT.md): the robot's sidecar
# (a Raspberry Pi) owns the camera — capturing a frame is the [sense] effect
# and it stays on the robot. JUDGING the frame runs wherever the model
# horsepower lives (a Mac Studio serving Ollama, a Jetson, anything behind a
# LiteLLM proxy), reached over plain HTTP. Two judgments, two routes:
#
#   1. detect_object — the SIDECAR captures a head-camera frame and ships the
#      already-captured JPEG to the vision service; the program gets back a
#      normalized 2D bounding box. Honestly 2D: turning a box into a world
#      pose needs depth or calibration this hardware doesn't have.
#   2. list_visible_items — the PROGRAM reads the camera itself ([sense]),
#      then hands the image to the service as [net]-only judgment — the same
#      perceive/judge line the fridge-report demo draws.
#
# Run it:  make vision-split   (or: bash scripts/demo.sh xlerobot_vision)
# The demo runner starts the vision service in MOCK mode (canned, labeled
# answers, no model) so this runs everywhere; against real hardware the same
# wiring answers from a real VLM — see deploy/VISION_SPLIT.md.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "../src/types" as t

import "../src/sense" as sense

import "../src/skills" as sk

# Sensors-only envelope: cameras, no actuation. detect_object carries no
# authority (it never moves anything) so, like read_camera/locate_object,
# it is not skill-gated — the envelope documents intent.
fn sensor_grant() -> t.Grant {
  { skills: ["read_camera"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 }
}

fn vision_url() -> [env] Str {
  match env.get("LEX_VISION_URL") {
    Some(u) => u,
    None => "http://127.0.0.1:8901",
  }
}

# Pull the jpeg_b64 value out of read_camera's frame JSON ("" when the tier
# has no real encoder — the stub's honest empty frame).
fn jpeg_of(json :: Str) -> Str {
  let parts := str.split(json, "\"jpeg_b64\"")
  match list.head(list.tail(parts)) {
    None => "",
    Some(rest) => match list.head(list.tail(str.split(rest, "\""))) {
      None => "",
      Some(b) => b,
    },
  }
}

fn run() -> [net, sense, io, env] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: sensor_grant() }
  let __1 := match sense.detect_object(robot, "cup") {
    Ok(resp) => if str.contains(resp, "\"found\":true") {
      let __a := io.print("detect: cup found (judged by the vision service)")
      io.print(str.concat("  ", resp))
    } else {
      let __b := io.print("detect: cup not found")
      io.print(str.concat("  ", resp))
    },
    Err(e) => io.print(str.concat("detect_object failed: ", e)),
  }
  let __2 := match sense.read_camera(robot, "head") {
    Err(e) => io.print(str.concat("read_camera failed: ", e)),
    Ok(frame) => match sk.list_visible_items(vision_url(), jpeg_of(frame)) {
      Err(e) => io.print(str.concat("list_visible_items failed: ", e)),
      Ok(items) => {
        let __c := io.print("items from the vision service:")
        let __d := list.map(items, fn (it :: Str) -> [io] Unit {
          io.print(str.concat("  - ", it))
        })
        ()
      },
    },
  }
  ()
}

