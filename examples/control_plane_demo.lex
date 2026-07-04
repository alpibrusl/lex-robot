# examples/control_plane_demo.lex — issue / scope / revoke capability tokens,
# with a reviewable trail (platform kernel, #73).
#
# Today a Grant is a literal hardcoded into whichever demo constructs it — no
# record of who authorized it, for how long, or how to take it back. This shows
# the missing verb set live: an ISSUER (a did:lex, src/identity.lex) issues a
# scoped, time-boxed, revocable TOKEN (src/control_plane.lex) to a SUBJECT
# did:lex. Every issuance/admission/refusal/revocation is written to a
# lex-trail log, so the control plane is reviewable, not just enforced.
#
# Five token presentations, in order:
#   1. valid token, right subject, unexpired, unrevoked -> ADMITTED, and the
#      SAME admitted Grant still has an out-of-workspace target refused by
#      grant.lex's own check (the control plane governs how a Grant came to
#      exist, not what it permits — the physical layer still applies)
#   3. the token presented by a DIFFERENT subject -> refused (not issued to them)
#   4. a REVOKED token id -> refused, even though the signature is still valid
#   5. an EXPIRED token -> refused, even though nothing else changed
#   6. a FORGED token (signed by an attacker's key, not the trusted issuer's)
#      -> refused: signature invalid
#
# No sidecar, no hardware — the authority layer, exactly like the reputation
# and identity kernel pieces. Run: lex run --allow-effects io,sql,time,fs_write \
#   examples/control_plane_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "../src/types" as t

import "../src/grant" as grant

import "../src/identity" as id

import "../src/control_plane" as cp

import "lex-trail/src/log" as trail

import "lex-trail/src/event" as ev

fn depot_grant() -> t.Grant {
  { skills: ["move_to", "grasp"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 15.0, max_grip_force: 20.0, budget_actions: 10, budget_wall_ms: 60000 }
}

fn q(s :: Str) -> Str {
  str.join(["\"", s, "\""], "")
}

fn emit(log :: trail.Log, kind :: Str, payload :: Str) -> [sql, time] Nil {
  match trail.append(log, kind, None, payload) {
    Ok(_) => (),
    Err(_) => (),
  }
}

# Present a token; log + report the outcome. If admitted, also prove
# composability: the embedded Grant still gates concrete commands through the
# SAME grant.lex checks skills.move_to/grasp would run.
fn present(log :: trail.Log, label :: Str, issuer_pk :: Str, subject :: Str, tok :: cp.Token, now :: Int, revoked :: List[Str]) -> [io, sql, time, crypto] Nil {
  match cp.verify(issuer_pk, subject, tok, now, revoked) {
    Err(e) => {
      let __e := emit(log, "grant_refused", str.join(["{\"token_id\":", q(tok.token_id), ",\"presented_as\":", q(subject), ",\"reason\":", q(e), "}"], ""))
      io.print(str.join(["  [", label, "] REFUSED — ", e], ""))
    },
    Ok(g) => {
      let __a := emit(log, "grant_admitted", str.join(["{\"token_id\":", q(tok.token_id), ",\"subject\":", q(subject), "}"], ""))
      let in_ws := grant.in_workspace(g, { x: 0.5, y: 0.5, z: 0.5 })
      let out_ws := grant.in_workspace(g, { x: 2.0, y: 2.0, z: 2.0 })
      let clamped := grant.clamp_grip(g, 99.0)
      io.print(str.join(["  [", label, "] ADMITTED — in-workspace move: ", if in_ws {
        "permitted"
      } else {
        "denied"
      }, "; out-of-workspace move: ", if out_ws {
        "permitted (BUG)"
      } else {
        "denied — control plane doesn't bypass the physical layer"
      }, "; 99N grasp clamped to ", flt.to_str(clamped), "N"], ""))
    },
  }
}

fn review(log :: trail.Log) -> [io, sql] Nil {
  match trail.range(log, 0, 9999999999999) {
    Err(_) => io.print("review failed"),
    Ok(evs) => {
      let issued := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
        if e.kind == "token_issued" {
          acc + 1
        } else {
          acc
        }
      })
      let admitted := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
        if e.kind == "grant_admitted" {
          acc + 1
        } else {
          acc
        }
      })
      let refused := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
        if e.kind == "grant_refused" {
          acc + 1
        } else {
          acc
        }
      })
      let revoked := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
        if e.kind == "token_revoked" {
          acc + 1
        } else {
          acc
        }
      })
      io.print(str.join(["\nreview trail: ", int.to_str(issued), " issued, ", int.to_str(admitted), " admitted, ", int.to_str(refused), " refused, ", int.to_str(revoked), " revoked — every decision is on the record"], ""))
    },
  }
}

fn run() -> [io, sql, time, fs_write, crypto] Int {
  match id.derive("depot-issuer", "issuer-seed-0001") {
    Err(e) => {
      let __d := io.print(str.concat("issuer derive failed: ", e))
      1
    },
    Ok(issuer) => match id.derive("mallory", "mallory-seed-0001") {
      Err(e) => {
        let __d := io.print(str.concat("attacker derive failed: ", e))
        1
      },
      Ok(attacker) => match trail.open_memory() {
        Err(e) => {
          let __d := io.print(str.concat("trail open failed: ", e))
          1
        },
        Ok(log) => {
          let now := 1000000
          match cp.issue(issuer, "did:lex:robot:arm-1", "tok-1", depot_grant(), now, 60000) {
            Err(e) => {
              let __d := io.print(str.concat("issue failed: ", e))
              1
            },
            Ok(tok) => {
              let __i := emit(log, "token_issued", str.join(["{\"token_id\":\"tok-1\",\"subject\":\"did:lex:robot:arm-1\",\"issuer\":\"", issuer.did, "\",\"expires_at_ms\":", int.to_str(tok.expires_at_ms), "}"], ""))
              let __0 := io.print("=== issue / scope / revoke capability tokens ===\n")
              let __1 := present(log, "1. valid, right subject", issuer.pubkey_b64, "did:lex:robot:arm-1", tok, now + 1000, [])
              let __2 := present(log, "3. wrong subject presents it", issuer.pubkey_b64, "did:lex:robot:arm-2", tok, now + 1000, [])
              let __rv := emit(log, "token_revoked", str.join(["{\"token_id\":\"tok-1\",\"reason\":\"operator revoked early\"}"], ""))
              let __3 := present(log, "4. revoked", issuer.pubkey_b64, "did:lex:robot:arm-1", tok, now + 1000, ["tok-1"])
              let __4 := present(log, "5. expired", issuer.pubkey_b64, "did:lex:robot:arm-1", tok, now + 61000, [])
              match cp.issue(attacker, "did:lex:robot:arm-1", "tok-1", depot_grant(), now, 60000) {
                Err(e) => {
                  let __d := io.print(str.concat("forge failed: ", e))
                  1
                },
                Ok(forged) => {
                  let __5 := present(log, "6. forged (attacker's key)", issuer.pubkey_b64, "did:lex:robot:arm-1", forged, now + 1000, [])
                  let __rv2 := review(log)
                  0
                },
              }
            },
          }
        },
      },
    },
  }
}

