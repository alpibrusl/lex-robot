# lex-robot/examples/a2a_robot_demo.lex — serve the bounded XLeRobot skills
# over the standard Google A2A protocol, with the grant envelope intact.
#
# This is the runnable companion to tests/test_a2a_robot_grant.lex: it boots
# the real A2A HTTP endpoint (src/a2a_robot_server.lex) under a concrete
# dual-arm + base grant. Any A2A client — lex-agent's own client.lex, or a
# third-party ADK/LangGraph/CrewAI/AutoGen agent — can fetch the AgentCard at
# `/.well-known/agent.json` and drive the robot via `tasks/send`, gated by the
# exact same grant + budget + trail rails the in-process API and the MCP
# front door (mcp_server_demo.lex) use.
#
# The grant below is the authority envelope: only move_arm / grasp_arm /
# move_base / read_base are listed (move_to / grasp / connect_charger /
# listen calls all return "denied:…"), the left arm's workspace is the
# +y half of the reach box, the base's floor area is a 4x3m room, and the
# run is capped at 200 actions / 120 s.
#
# Run (the effect wall: serving actuation REQUIRES --allow-effects
# sense,actuate — withhold them and the binary cannot drive the robot even
# over the network; llm,proc are required too — see a2a_robot_server.lex):
#   lex run \
#     --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#     examples/a2a_robot_demo.lex run
#
# Smoke it without an A2A client:
#   curl -s localhost:8766/.well-known/agent.json | head -c 400
#   curl -s localhost:8766/ -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{
#     "id":"t_1","contextId":"ctx_1","skill":"move_arm",
#     "message":{"kind":"message","messageId":"m1","role":"user",
#                "parts":[{"type":"data","data":{"arm":"left","x":0.3,"y":0.2,"z":0.2}}]}}}'

import "../src/types" as t

import "../src/a2a_robot_server" as a2a

fn demo_grant() -> t.Grant {
  {
    skills: ["move_arm", "grasp_arm", "move_base", "read_base"],
    ws_min: { x: 0.05, y: 0.0, z: 0.0 },
    ws_max: { x: 0.45, y: 0.35, z: 0.5 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 15.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}

fn run() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, sense, actuate] Nil {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  a2a.run(robot, 8766, "http://localhost:8766", "/tmp/lex-robot-a2a-trail.db", "/tmp/lex-robot-a2a-ledger.db")
}
