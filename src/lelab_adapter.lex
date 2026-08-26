# lex-robot/src/lelab_adapter.lex — leLab's HTTP surface, in Lex, over the
# governed skill API: the SENSING half, and the entry point that has nothing
# else. The Lex-native replacement for sidecar/lelab_adapter.py (same routes,
# same port, same refusal philosophy — see docs/LELAB.md).
#
# `huggingface/leLab` is LeRobot's web UI. Its own backend drives LeRobot's
# Robot classes directly, so running it beside lex-robot on the same arms
# means two independent authority paths to the same servos, one of which no
# grant covers. This module is the other arrangement: leLab's frontend talks
# to a Lex program that holds a Grant, and every robot-touching request goes
# through skills.lex / sense.lex — the grant gate, then the sidecar's own
# checks, then the ledger at GET /governance.
#
# WHY THIS IS LEX AND NOT PYTHON. The Python version was a translator: it
# was bounded only because the sidecar it called happened to check the
# grant. It had no authority model of its own, and its read-only story was a
# dict of 501 strings I wrote by hand and could have got wrong. Here the
# same property is a type:
#
#   lelab_adapter.lex       run_readonly()  [net, sense]           — this file
#   lelab_adapter_full.lex  run()           [net, sense, actuate]  — the other
#
# The split is not tidiness, it is the guarantee. `--allow-effects` is checked
# against every function reachable in the import graph, not just the ones the
# chosen entry point calls: a single file importing `skills` is rejected under
# `io,env,net,sense` even if the entry point never actuates. So the read-only
# adapter has to be a module with **no import path to an actuating function**,
# and this is that module — it imports `sense` and never `skills`, exactly the
# reason sense.lex was split off in the first place.
#
# The upshot: "leLab drives a robot it cannot move" is not a flag, a config, or
# a hand-written 501 table. Adding a `skills.move_arm` call to this file makes
# `lex check` reject it, and `lex run --allow-effects io,env,net,sense` proves
# at startup that nothing reachable from here can actuate.
#
# Run:
#   python3 sidecar/xlerobot_sidecar.py &                    # the robot
#   lex run --allow-effects io,env,net,sense,actuate \
#     src/lelab_adapter_full.lex run                         # full
#   lex run --allow-effects io,env,net,sense \
#     src/lelab_adapter.lex run_readonly                     # look, don't touch
#
# Env:
#   LEX_LELAB_PORT          port to serve on (default 8000, leLab's own)
#   LEX_ROBOT_SIDECAR_URL   the governed sidecar (default http://localhost:8900)

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "std.map" as map

import "std.env" as env

import "std.io" as io

import "std.net" as net

import "lex-schema/json_value" as jv

import "./types" as t

import "./sense" as sense

# ── leLab's joint vocabulary ──────────────────────────────────────────────
# lex-robot reads SO-101 motor names; leLab's frontend renders URDF names.
# Same six joints, two vocabularies — translate rather than making either
# side learn the other's. An unrecognised name passes through unchanged:
# a seventh axis nobody taught this table about should appear in the UI as
# itself, not be dropped or renamed to a guess.
fn urdf_name(motor :: Str) -> Str
  examples {
    urdf_name("shoulder_pan") => "Rotation",
    urdf_name("shoulder_lift") => "Pitch",
    urdf_name("elbow_flex") => "Elbow",
    urdf_name("wrist_flex") => "Wrist_Pitch",
    urdf_name("wrist_roll") => "Wrist_Roll",
    urdf_name("gripper") => "Jaw",
    urdf_name("seventh_axis") => "seventh_axis"
  }
{
  if motor == "shoulder_pan" {
    "Rotation"
  } else {
    if motor == "shoulder_lift" {
      "Pitch"
    } else {
      if motor == "elbow_flex" {
        "Elbow"
      } else {
        if motor == "wrist_flex" {
          "Wrist_Pitch"
        } else {
          if motor == "wrist_roll" {
            "Wrist_Roll"
          } else {
            if motor == "gripper" {
              "Jaw"
            } else {
              motor
            }
          }
        }
      }
    }
  }
}

# Strip the arm prefix the sidecar adds ("left_shoulder_pan" → "shoulder_pan")
# so urdf_name sees a bare motor name.
fn strip_arm_prefix(name :: Str, arm :: Str) -> Str
  examples {
    strip_arm_prefix("left_shoulder_pan", "left") => "shoulder_pan",
    strip_arm_prefix("gripper", "left") => "gripper",
    strip_arm_prefix("right_elbow_flex", "right") => "elbow_flex"
  }
{
  match str.strip_prefix(name, str.concat(arm, "_")) {
    Some(bare) => bare,
    None => name,
  }
}

# ── The refusal table ─────────────────────────────────────────────────────
# leLab's surface is much wider than the governed skill surface. The honest
# answer to a route the skill API cannot express is a 501 naming the reason,
# not a plausible-looking implementation that reaches around the grant.
#
# Two kinds, and the distinction is the whole point:
#   "not expressible" — implementing it here would be a second path to the
#                       servos that no grant covers.
#   "not this layer"  — it never touches the arm, so there is nothing to
#                       govern; run leLab against LeRobot directly.
fn not_expressible(why :: Str) -> Str {
  str.join(["not expressible through the lex skill API: ", why, ". Implementing it here would mean a second path to the servos that the grant does not cover, which is the one thing this layer exists to prevent."], "")
}

fn not_this_layer(why :: Str) -> Str {
  str.join(["not lex-robot's layer: ", why, ". It never touches the arm, so there is nothing to govern -- run leLab against LeRobot directly for it."], "")
}

# The first path segment, so one entry covers every subpath under it
# (`/jobs/17/logs` is answered by the `/jobs` entry).
fn head_segment(path :: Str) -> Str
  examples {
    head_segment("/jobs/17/logs") => "/jobs",
    head_segment("/jobs") => "/jobs",
    head_segment("/") => "/",
    head_segment("/move-arm") => "/move-arm"
  }
{
  let rest := match str.strip_prefix(path, "/") {
    Some(x) => x,
    None => path,
  }
  match list.head(str.split(rest, "/")) {
    None => path,
    Some(first) => str.concat("/", first),
  }
}

fn refusal_for(path :: Str) -> Option[Str]
  examples {
    refusal_for("/joint-positions") => None,
    refusal_for("/move-arm") => None
  }
{
  let head := head_segment(path)
  if head == "/start-calibration" or head == "/stop-calibration" or head == "/calibration-status" or head == "/complete-calibration-step" or head == "/calibration-configs" {
    Some(not_expressible("no calibration skill exists, and calibration drives the servos through their full range"))
  } else {
    if head == "/start-inference" or head == "/stop-inference" or head == "/inference-status" {
      Some(not_expressible("this sidecar exposes no policy-execution skill (gym_sidecar.py's run_policy is the governed shape, and it is a different sidecar)"))
    } else {
      if head == "/available-ports" or head == "/start-port-detection" or head == "/detect-port-after-disconnect" or head == "/save-robot-port" or head == "/robot-port" {
        Some(not_expressible("port discovery is serial-bus enumeration, below the skill API"))
      } else {
        if head == "/ws" or head == "/ws-test" {
          Some(not_expressible("leLab streams joint data over a WebSocket; the sidecar's own /stream is the governed equivalent and speaks a different shape"))
        } else {
          if head == "/recording-rerecord-episode" {
            Some(not_expressible("teach records one demonstration per start/stop, with no episode index to re-take"))
          } else {
            if head == "/jobs" {
              Some(not_this_layer("training is LeRobot's job"))
            } else {
              if head == "/upload-dataset" or head == "/dataset-info" or head == "/delete-dataset" or head == "/dataset-repair" {
                Some(not_this_layer("dataset management is LeRobot's job"))
              } else {
                if head == "/hf-auth" or head == "/hf-auth-status" {
                  Some(not_this_layer("Hub credentials are LeRobot's job"))
                } else {
                  if head == "/system" {
                    Some(not_this_layer("dependency installs are LeRobot's job"))
                  } else {
                    if head == "/get-configs" or head == "/robots" or head == "/save-robot-config" or head == "/robot-config" {
                      Some(not_this_layer("robot config files are LeRobot's job"))
                    } else {
                      None
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ── Request parsing ───────────────────────────────────────────────────────
fn body_field_str(body :: Str, key :: Str, dflt :: Str) -> Str {
  match jv.parse(body) {
    Err(_) => dflt,
    Ok(j) => match jv.get_field(j, key) {
      None => dflt,
      Some(v) => match jv.as_str(v) {
        Some(s) => s,
        None => dflt,
      },
    },
  }
}

fn body_has(body :: Str, key :: Str) -> Bool {
  match jv.parse(body) {
    Err(_) => false,
    Ok(j) => match jv.get_field(j, key) {
      None => false,
      Some(_) => true,
    },
  }
}

fn body_field_float(body :: Str, key :: Str) -> Option[Float] {
  match jv.parse(body) {
    Err(_) => None,
    Ok(j) => match jv.get_field(j, key) {
      None => None,
      Some(v) => match jv.as_float(v) {
        Some(f) => Some(f),
        None => match jv.as_int(v) {
          Some(i) => Some(int.to_float(i)),
          None => None,
        },
      },
    },
  }
}

# leLab's POST /move-arm → an absolute Cartesian target, or a refusal.
#
# leLab's own TeleoperateRequest is {leader_port, follower_port, ...}: "mirror
# this leader arm onto that follower until told to stop". That is a continuous
# stream with no target in it, and there is no leader on this side to read, so
# it is refused rather than approximated. A body carrying an absolute target --
# what a jog UI sends -- is a move_arm, and goes through the grant like any
# other command. A body missing an axis is refused too: defaulting z to 0 would
# drive the arm at the floor.
fn move_arm_request(body :: Str) -> Result[t.Pose, Str] {
  if body_has(body, "leader_port") or body_has(body, "follower_port") {
    Err(not_expressible("leader-follower teleoperation is a continuous mirroring loop between two arms, and this sidecar exposes no leader arm to read; the grant gates discrete commands, which is not that"))
  } else {
    match body_field_float(body, "x") {
      None => Err("absolute Cartesian target required; missing or non-numeric x"),
      Some(x) => match body_field_float(body, "y") {
        None => Err("absolute Cartesian target required; missing or non-numeric y"),
        Some(y) => match body_field_float(body, "z") {
          None => Err("absolute Cartesian target required; missing or non-numeric z"),
          Some(z) => Ok({ pos: { x: x, y: y, z: z }, rx: 0.0, ry: 0.0, rz: 0.0 }),
        },
      },
    }
  }
}

type TeachRequest = { arm :: Str, name :: Str, task :: Str, fps :: Float, seconds :: Float }

# leLab's RecordingRequest -> teach_start args, or a refusal.
#
# The fields that survive are the ones a hand-guided demonstration actually
# has. `num_episodes` does not: teach records one demonstration per start/stop,
# so a request for several is refused rather than silently recording one and
# reporting success. push_to_hub is refused as LeRobot's job.
fn recording_request(body :: Str) -> Result[TeachRequest, Str] {
  let episodes := match body_field_float(body, "num_episodes") {
    None => 1.0,
    Some(n) => n,
  }
  if episodes > 1.0 {
    Err("teach records ONE demonstration per start/stop; num_episodes > 1 would silently record one. Drive the loop from the UI, one /start-recording per episode.")
  } else {
    if body_field_str(body, "push_to_hub", "") == "true" {
      Err(not_this_layer("Hub upload is LeRobot's job"))
    } else {
      let repo := body_field_str(body, "dataset_repo_id", "lelab")
      Ok({ arm: body_field_str(body, "arm", "left"), name: str.replace(repo, "/", "_"), task: body_field_str(body, "single_task", ""), fps: match body_field_float(body, "fps") {
        None => 20.0,
        Some(v) => v,
      }, seconds: match body_field_float(body, "episode_time_s") {
        None => 120.0,
        Some(v) => v,
      } })
    }
  }
}

fn requested_arm(body :: Str) -> Result[Str, Str] {
  let arm := body_field_str(body, "arm", "left")
  if arm == "left" or arm == "right" {
    Ok(arm)
  } else {
    Err(str.join(["unknown arm '", arm, "' (use left|right)"], ""))
  }
}

# ── Responses ─────────────────────────────────────────────────────────────
fn json_headers() -> Map[Str, Str] {
  map.from_list([("content-type", "application/json")])
}

fn json_escape(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn ok_json(body :: Str) -> Response {
  { status: 200, body: BodyStr(body), headers: json_headers() }
}

# A refusal is a 501 that names the reason and points at the ledger, so the
# operator can see the whole picture rather than a bare status code.
fn refused(path :: Str, reason :: Str, sidecar_url :: Str) -> Response {
  { status: 501, body: BodyStr(str.join(["{\"success\":false,\"error\":\"refused by lex-robot\",\"path\":\"", json_escape(path), "\",\"detail\":\"", json_escape(reason), "\",\"see\":\"", json_escape(sidecar_url), "/governance\"}"], "")), headers: json_headers() }
}

fn not_found(path :: Str) -> Response {
  { status: 404, body: BodyStr(str.join(["{\"success\":false,\"error\":\"no such route: ", json_escape(path), "\",\"see\":\"/lex/routes\"}"], "")), headers: json_headers() }
}

fn outcome_json(o :: t.Outcome) -> Str {
  match o {
    Reached => "{\"success\":true,\"governed\":true,\"outcome\":\"reached\"}",
    Timeout => "{\"success\":false,\"governed\":true,\"outcome\":\"timeout\"}",
    Stalled(m) => str.join(["{\"success\":false,\"governed\":true,\"outcome\":\"stalled\",\"detail\":\"", json_escape(m), "\"}"], ""),
    Denied(m) => str.join(["{\"success\":false,\"governed\":true,\"outcome\":\"denied\",\"detail\":\"", json_escape(m), "\"}"], ""),
    Killed(m) => str.join(["{\"success\":false,\"governed\":true,\"outcome\":\"killed\",\"detail\":\"", json_escape(m), "\"}"], ""),
  }
}

# ── The grant this adapter holds ──────────────────────────────────────────
# Deliberately narrow: teach_free / teach_hold are NOT granted. Freeing an arm
# drops servo torque and it falls unless a hand is already on it, and leLab's
# UI has no button that means "I am holding the arm right now". Recording is
# granted; making the arm limp from a browser is not.
#
# Mirrors manifests/xlerobot.capsule.json's actuation block, the same way
# every demo in examples/ declares its envelope inline. The sidecar re-checks
# all of it (defense in depth for callers that never went through Lex), so a
# drift here narrows what leLab can ask for but can never widen what the
# robot will do.
fn arm_grant() -> t.Grant {
  { skills: ["move_arm", "read_joints", "read_camera", "teach_start", "teach_stop"], ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 15.0, budget_actions: 10000, budget_wall_ms: 0 }
}

fn robot(sidecar_url :: Str) -> t.Robot {
  { sidecar_url: sidecar_url, grant: arm_grant() }
}

# ── Route table, served as data ───────────────────────────────────────────
# The only question that matters when you point a UI at this thing is which
# of its buttons work and which will refuse, so answer it in one GET rather
# than making somebody find out one click at a time.
fn routes_json(sidecar_url :: Str, readonly :: Bool) -> Str {
  let mode := if readonly {
    "readonly"
  } else {
    "full"
  }
  let actuating := if readonly {
    "\"POST /move-arm, /start-recording, /stop-recording, /recording-exit-early -- NOT compiled into this entry point: it declares no actuate effect and cannot reach skills.lex\""
  } else {
    "\"POST /move-arm -> skills.move_arm; /start-recording -> skills.teach_start; /stop-recording, /recording-exit-early -> skills.teach_stop -- all grant-gated\""
  }
  str.join(["{\"mode\":\"", mode, "\",\"sidecar\":\"", json_escape(sidecar_url), "\",\"implemented\":[", "\"GET /health -> sense.read_joints reachability\",", "\"GET /joint-positions -> sense.read_joints_arm on both arms, URDF names\",", "\"GET /available-cameras -> sense.read_camera probe (live frames only)\",", "\"GET /recording-status -> sense.teach_status\",", "\"GET /datasets -> sense.teach_list\",", "\"GET /teleoperation-status -> adapter state (no robot call)\",", "\"GET /lex/routes -> this table\",", actuating, "],\"refused\":\"calibration, inference, port detection, the joint-data WebSocket, MJPEG camera-feed restreaming, training, Hub upload, auth, dataset management -- each with its reason; see docs/LELAB.md\"}"], "")
}

# ── Sensing routes: [net, sense] ONLY ─────────────────────────────────────
# Every route here is reachable from run_readonly. Nothing in this function
# may actuate -- and that is enforced by the effect row, not by review.
fn nth_float(xs :: List[Float], idx :: Int) -> Option[Float]
  examples {
    nth_float([1.0, 2.0, 3.0], 1) => Some(2.0),
    nth_float([1.0], 4) => None,
    nth_float([], 0) => None
  }
{
  list.fold(list.enumerate(xs), None, fn (acc :: Option[Float], p :: (Int, Float)) -> Option[Float] {
    match p {
      (i, v) => if i == idx {
        Some(v)
      } else {
        acc
      },
    }
  })
}

# One arm's parallel names/positions arrays as leLab's flat entries. Pure, so
# the round trip that matters -- sidecar vocabulary in, UI vocabulary out -- is
# checked by the examples below rather than by pointing a browser at it.
#
# A name with no matching position is dropped rather than paired with a zero: a
# UI showing a confident 0.0 for a joint nobody read is worse than a UI showing
# nothing.
fn joint_entries(arm :: Str, names :: List[Str], positions :: List[Float]) -> List[Str]
  examples {
    joint_entries("left", ["left_shoulder_pan", "left_gripper"], [1.5, 0.0]) => ["\"left_Rotation\":1.5", "\"left_Jaw\":0"],
    joint_entries("right", ["right_elbow_flex"], []) => [],
    joint_entries("left", ["left_seventh_axis"], [0.25]) => ["\"left_seventh_axis\":0.25"]
  }
{
  list.fold(list.enumerate(names), [], fn (acc :: List[Str], p :: (Int, Str)) -> List[Str] {
    match p {
      (i, name) => match nth_float(positions, i) {
        None => acc,
        Some(v) => list.concat(acc, [str.join(["\"", arm, "_", urdf_name(strip_arm_prefix(name, arm)), "\":", flt.to_str(v)], "")]),
      },
    }
  })
}

fn json_strs(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    None => [],
    Some(v) => match jv.as_list(v) {
      None => [],
      Some(xs) => list.map(xs, fn (x :: jv.Json) -> Str {
        match jv.as_str(x) {
          Some(sv) => sv,
          None => "",
        }
      }),
    },
  }
}

fn json_floats(j :: jv.Json, key :: Str) -> List[Float] {
  match jv.get_field(j, key) {
    None => [],
    Some(v) => match jv.as_list(v) {
      None => [],
      Some(xs) => list.map(xs, fn (x :: jv.Json) -> Float {
        match jv.as_float(x) {
          Some(f) => f,
          None => match jv.as_int(x) {
            Some(i) => int.to_float(i),
            None => 0.0,
          },
        }
      }),
    },
  }
}

fn arm_entries(arm :: Str, raw :: Str) -> List[Str] {
  match jv.parse(raw) {
    Err(_) => [],
    Ok(j) => joint_entries(arm, json_strs(j, "names"), json_floats(j, "positions")),
  }
}

# Both arms, because leLab's single-arm shape has nowhere to put a second one
# and dropping it silently would hide half the robot. An arm that fails to
# read is reported as an error entry rather than omitted -- "not there" and
# "did not answer" are different facts.
fn joint_positions(r :: t.Robot) -> [net, sense] Str {
  let per_arm := list.map(["left", "right"], fn (arm :: Str) -> [net, sense] List[Str] {
    match sense.read_joints_arm(r, arm) {
      Err(e) => [str.join(["\"", arm, "_error\":\"", json_escape(e), "\""], "")],
      Ok(raw) => arm_entries(arm, raw),
    }
  })
  let entries := list.fold(per_arm, [], fn (acc :: List[Str], xs :: List[Str]) -> List[Str] {
    list.concat(acc, xs)
  })
  str.join(["{\"success\":true,\"joint_positions\":{", str.join(entries, ","), "}}"], "")
}

# A camera that answers with an empty frame is NOT listed as available. The
# Tier-1 stub answers every read_camera with a 640x480 placeholder and no JPEG,
# and a UI told three cameras exist would show three dead panes; the honest
# answer is which ones are live.
fn camera_live(raw :: Str) -> Bool
  examples {
    camera_live("{\"width\":640,\"jpeg_b64\":\"\"}") => false,
    camera_live("{\"width\":640,\"jpeg_b64\":\"/9j/4AA\"}") => true,
    camera_live("{\"error\":\"not configured\"}") => false
  }
{
  match jv.parse(raw) {
    Err(_) => false,
    Ok(j) => match jv.get_field(j, "jpeg_b64") {
      None => false,
      Some(v) => match jv.as_str(v) {
        Some(sv) => not str.is_empty(sv),
        None => false,
      },
    },
  }
}

fn available_cameras(r :: t.Robot) -> [net, sense] Str {
  let live := list.fold(["head", "left", "right"], [], fn (acc :: List[Str], name :: Str) -> [net, sense] List[Str] {
    match sense.read_camera(r, name) {
      Err(_) => acc,
      Ok(raw) => if camera_live(raw) {
        list.concat(acc, [str.join(["\"", name, "\""], "")])
      } else {
        acc
      },
    }
  })
  str.join(["{\"status\":\"success\",\"cameras\":[", str.join(live, ","), "]}"], "")
}

# teach_status -> leLab's recording-status shape. Pure, so the mapping is
# checked by the examples rather than by watching a browser.
fn recording_status(raw :: Str) -> Str
  examples {
    recording_status("{\"recording\": true, \"frames\": 12}") => "{\"recording_active\":true,\"current_phase\":\"recording\",\"available_controls\":{\"stop_recording\":true,\"exit_early\":true,\"rerecord_episode\":false},\"message\":\"teaching\"}",
    recording_status("not json") => "{\"recording_active\":false,\"current_phase\":\"completed\",\"available_controls\":{\"stop_recording\":false,\"exit_early\":false,\"rerecord_episode\":false},\"message\":\"idle\"}"
  }
{
  let active := match jv.parse(raw) {
    Err(_) => false,
    Ok(j) => match jv.get_field(j, "recording") {
      None => false,
      Some(v) => match jv.as_bool(v) {
        Some(b) => b,
        None => false,
      },
    },
  }
  let flag := if active {
    "true"
  } else {
    "false"
  }
  let phase := if active {
    "recording"
  } else {
    "completed"
  }
  let msg := if active {
    "teaching"
  } else {
    "idle"
  }
  str.join(["{\"recording_active\":", flag, ",\"current_phase\":\"", phase, "\",\"available_controls\":{\"stop_recording\":", flag, ",\"exit_early\":", flag, ",\"rerecord_episode\":false},\"message\":\"", msg, "\"}"], "")
}

# Every route here is reachable from run_readonly, and nothing here may
# actuate -- enforced by the effect row, not by review.
fn handle_sense(r :: t.Robot, readonly :: Bool, path :: Str) -> [net, sense] Option[Response] {
  if path == "/health" {
    match sense.read_joints(r) {
      Err(e) => Some({ status: 503, body: BodyStr(str.join(["{\"status\":\"unhealthy\",\"detail\":\"", json_escape(e), "\"}"], "")), headers: json_headers() }),
      Ok(_) => Some(ok_json(str.join(["{\"status\":\"healthy\",\"message\":\"governed by lex-robot\",\"mode\":\"", if readonly {
        "readonly"
      } else {
        "full"
      }, "\"}"], ""))),
    }
  } else {
    if path == "/joint-positions" {
      Some(ok_json(joint_positions(r)))
    } else {
      if path == "/available-cameras" {
        Some(ok_json(available_cameras(r)))
      } else {
        if path == "/recording-status" {
          match sense.teach_status(r) {
            Err(e) => Some(ok_json(str.join(["{\"recording_active\":false,\"current_phase\":\"error\",\"error\":\"", json_escape(e), "\"}"], ""))),
            Ok(raw) => Some(ok_json(recording_status(raw))),
          }
        } else {
          if path == "/datasets" {
            match sense.teach_list(r) {
              Err(e) => Some(ok_json(str.join(["{\"datasets\":[],\"error\":\"", json_escape(e), "\"}"], ""))),
              Ok(raw) => Some(ok_json(str.join(["{\"source\":\"lex-robot/teach\",\"library\":", raw, "}"], ""))),
            }
          } else {
            if path == "/lex/routes" {
              Some(ok_json(routes_json(r.sidecar_url, readonly)))
            } else {
              if path == "/teleoperation-status" {
                Some(ok_json("{\"teleoperation_active\":false,\"available_controls\":{\"stop_teleoperation\":false},\"message\":\"governed jog session (bounded commands, not leader-follower)\"}"))
              } else {
                None
              }
            }
          }
        }
      }
    }
  }
}

# ── Shared tail: refusals and 404s, for both entry points ─────────────────
fn tail_response(sidecar_url :: Str, path :: Str) -> Response {
  match refusal_for(path) {
    Some(reason) => refused(path, reason, sidecar_url),
    None => not_found(path),
  }
}

fn cfg_port() -> [env] Int {
  match env.get("LEX_LELAB_PORT") {
    None => 8000,
    Some(v) => match str.to_int(v) {
      Some(p) => p,
      None => 8000,
    },
  }
}

fn cfg_sidecar() -> [env] Str {
  match env.get("LEX_ROBOT_SIDECAR_URL") {
    None => "http://localhost:8900",
    Some(v) => if str.is_empty(v) {
      "http://localhost:8900"
    } else {
      v
    },
  }
}

# ── Entry points ──────────────────────────────────────────────────────────
# The read-only adapter: leLab's UI, a robot it cannot move.
#
# This entry point declares `[io, env, net, sense]` and calls only
# `handle_sense`. It is not that the actuating routes are switched off -- they
# are not in this program's effect row, so `lex check` rejects any edit that
# tries to reach one from here. That is the property the Python adapter could
# only assert in a comment.
fn run_readonly() -> [io, env, net, sense] Nil {
  let port := cfg_port()
  let url := cfg_sidecar()
  let r := robot(url)
  let __lex_discard_4 := io.print(str.join(["lex-robot leLab adapter [READ-ONLY] on http://127.0.0.1:", int.to_str(port)], ""))
  let __lex_discard_5 := io.print("  no actuate effect in this entry point -- the arm cannot be moved from here")
  net.serve_fn(port, fn (req :: Request) -> [net, sense] Response {
    match handle_sense(r, true, req.path) {
      Some(res) => res,
      None => match refusal_for(req.path) {
        Some(reason) => refused(req.path, reason, url),
        None => if req.path == "/move-arm" {
          refused(req.path, "this adapter was started read-only: the actuating routes are not compiled into this entry point (it declares no `actuate` effect), so there is nothing here to reach around", url)
        } else {
          not_found(req.path)
        },
      },
    }
  })
}

