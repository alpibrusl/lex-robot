# lex-robot/examples/mcp_server_demo.lex — serve the bounded robot skills as an
# MCP server over HTTP, with the grant envelope intact.
#
# This is the runnable companion to tests/test_mcp_grant.lex: it boots the real
# MCP HTTP endpoint (src/mcp_server.lex) under a concrete grant. Point any MCP
# client at http://localhost:8765 and `tools/list` will advertise move_to /
# grasp / connect_charger / read_joints / read_camera; `tools/call` runs each
# through the same grant + budget + trail rails the in-process API uses.
#
# The grant below is the authority envelope: only move_to / grasp / read_joints
# are listed (connect_charger calls return "denied:…"), the workspace box is
# 0.1..0.5 × -0.3..0.3 × 0..0.4, grip force is clamped to 20 N, and the run is
# capped at 200 actions / 120 s.
#
# Run (the effect wall: serving actuation REQUIRES --allow-effects sense,actuate
# — withhold them and the binary cannot drive the arm even over the network):
#   lex run \
#     --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#     examples/mcp_server_demo.lex run
#
# Smoke it without an MCP client:
#   curl -s localhost:8765 -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -c 400
#   curl -s localhost:8765 -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"move_to","arguments":{"x":0.3,"y":0.0,"z":0.2}}}'

import "../src/types" as t

import "../src/mcp_server" as mcp

fn demo_grant() -> t.Grant {
  {
    skills: ["move_to", "grasp", "read_joints", "read_camera"],
    ws_min: { x: 0.1, y: 0.0 - 0.3, z: 0.0 },
    ws_max: { x: 0.5, y: 0.3, z: 0.4 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}

fn run() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, sense, actuate] Nil {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  mcp.run(robot, 8765, "/tmp/lex-robot-mcp-trail.db", "/tmp/lex-robot-mcp-ledger.db")
}
