# lex-robot/src/lelab_adapter_full.lex — the actuating half of the leLab
# adapter. Everything sensing lives in lelab_adapter.lex; this module adds the
# one route that moves the arm, and nothing else.
#
# Keeping the actuating surface in its own small module is what makes the
# read-only adapter provable: `--allow-effects` is checked over the whole
# reachable import graph, so a read-only entry point may not merely *avoid*
# calling `skills` — it must not be able to reach it. This file imports
# `skills`, so it can never be run under a policy that withholds `actuate`;
# lelab_adapter.lex imports only `sense`, so it always can.
#
# Run:
#   python3 sidecar/xlerobot_sidecar.py &
#   lex run --allow-effects io,env,net,sense,actuate \
#     src/lelab_adapter_full.lex run

import "std.str" as str

import "std.int" as int

import "std.io" as io

import "std.net" as net

import "./types" as t

import "./skills" as skills

import "./lelab_adapter" as base

# ── Actuating route: [net, sense, actuate] ────────────────────────────────
# Deliberately one function, so the actuating surface of this adapter is one
# thing a reviewer can read in full.
# Deliberately one function, so the actuating surface of this adapter is one
# thing a reviewer can read in full. Everything here is grant-gated by
# skills.lex before a byte reaches the sidecar.
fn handle_actuate(r :: t.Robot, method :: Str, path :: Str, body :: Str) -> [net, sense, actuate] Option[Response] {
  if method != "POST" {
    None
  } else {
    if path == "/move-arm" {
      match base.move_arm_request(body) {
        Err(reason) => Some(base.refused(path, reason, r.sidecar_url)),
        Ok(target) => match base.requested_arm(body) {
          Err(reason) => Some(base.refused(path, reason, r.sidecar_url)),
          Ok(arm) => Some(base.ok_json(base.outcome_json(skills.move_arm(r, arm, target)))),
        },
      }
    } else {
      if path == "/start-recording" {
        match base.recording_request(body) {
          Err(reason) => Some(base.refused(path, reason, r.sidecar_url)),
          Ok(req) => Some(base.ok_json(base.outcome_json(skills.teach_start(r, req.arm, req.name, req.task, req.fps, req.seconds)))),
        }
      } else {
        if path == "/stop-recording" or path == "/recording-exit-early" {
          Some(base.ok_json(base.outcome_json(skills.teach_stop(r))))
        } else {
          None
        }
      }
    }
  }
}

# The full adapter. Declares `actuate`, so `lex run` without it in
# --allow-effects refuses this entry point before the port is ever bound.
fn run() -> [io, env, net, sense, actuate] Nil {
  let port := base.cfg_port()
  let url := base.cfg_sidecar()
  let r := base.robot(url)
  let __lex_discard_1 := io.print(str.join(["lex-robot leLab adapter [full] on http://127.0.0.1:", int.to_str(port)], ""))
  let __lex_discard_2 := io.print(str.join(["  governed by ", url, "  -- every actuating request goes through skills.lex"], ""))
  let __lex_discard_3 := io.print(str.join(["  what is and isn't served: http://127.0.0.1:", int.to_str(port), "/lex/routes"], ""))
  net.serve_fn(port, fn (req :: Request) -> [net, sense, actuate] Response {
    match base.handle_sense(r, false, req.path) {
      Some(res) => res,
      None => match handle_actuate(r, req.method, req.path, req.body) {
        Some(res) => res,
        None => base.tail_response(url, req.path),
      },
    }
  })
}

