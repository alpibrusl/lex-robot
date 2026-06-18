# examples/nav_demo.lex — Physics navigation demo.
#
# A single robot visits all three bazaar stalls using real MuJoCo physics.
# The PHYSICS_URL env var must point to the gym_env/server.py instance.
# The sidecar at :8900 forwards move_to / scan_area to that server.
#
# Run via examples/physics_run.sh

import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.http"  as http
import "std.map"   as map
import "std.bytes" as bytes
import "std.env"   as env
import "std.time"  as time

import "lex-schema/json_value" as jv

fn sidecar_url() -> [env] Str {
  match env.get("SIDECAR_URL") {
    None    => "http://localhost:8900",
    Some(u) => u,
  }
}

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError    => "timeout",
    TlsError(m)     => str.concat("tls: ", m),
    NetworkError(m) => m,
    DecodeError(m)  => m,
  }
}

fn call_skill(skill :: Str, body :: Str) -> [net, env] Str {
  let url := str.concat(sidecar_url(), str.concat("/skill/", skill))
  let req0 := { method: "POST", url: url, headers: map.new(),
                body: Some(bytes.from_str(body)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 15000), "Content-Type", "application/json")
  match http.send(req) {
    Err(e) => str.concat("error: ", http_err_str(e)),
    Ok(r)  => match bytes.to_str(r.body) {
      Err(_) => "bad-utf8",
      Ok(s)  => s,
    },
  }
}

fn run() -> [net, io, time, env] Unit {
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   PHYSICS NAV DEMO  —  MuJoCo robot visits 3 stalls")
  let _ := io.print("══════════════════════════════════════════════════════")

  let scan := call_skill("scan_area", "{}")
  let _ := io.print(str.concat("  Initial scan: ", scan))
  let _ := time.sleep_ms(1000)

  let stalls := [
    { id: "pottery", name: "Pottery Palace" },
    { id: "textile", name: "Textile Traders" },
    { id: "spices",  name: "Spice Garden"    }
  ]
  let _ := list.fold(stalls, (), fn (_ :: Unit, s :: Stall) -> [net, io, time, env] Unit { nav_one(s) })

  io.print("══════════════════════════════════════════════════════")
}

import "std.list" as list

type Stall = { id :: Str, name :: Str }

fn nav_one(s :: Stall) -> [net, io, time, env] Unit {
  let _ := io.print(str.join(["  → Navigating to ", s.name, " ..."], ""))
  let body := str.join(["{\"stall\":\"", s.id, "\"}"], "")
  let result := call_skill("move_to", body)
  let _ := io.print(str.join(["  ← ", s.name, ": ", result], ""))
  time.sleep_ms(1500)
}
