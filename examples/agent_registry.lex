# examples/agent_registry.lex — durable did:lex identity + portable reputation
# (platform kernel, #73).
#
# The lex-games reputation registry accrues DID-keyed reputation from trails that
# replay clean — "a submission is a trail, not a score." This adds the two things
# that make the identity DURABLE and the reputation OWNED + PORTABLE:
#
#   1. Signed attribution. Each submission carries an ed25519 signature over a
#      claim binding {did, app, game, trail-hash} (src/identity.lex). The registry
#      binds a did to its key on first sight (trust-on-first-use) and thereafter
#      refuses any submission signed by a different key. Attribution is PROVEN,
#      not claimed — an impersonator earns nothing.
#   2. Cross-app profiles. A profile records the distinct APPS a did earned in, so
#      one identity's reputation accumulates across apps (robot, agent-ops, the
#      bazaar, …) — a loom-proven agent arrives in the bazaar with a reputation,
#      and vice-versa.
#
# Verified-only is preserved by REUSING lex-games' replay (the trusted verifier):
# reputation accrues iff the signature verifies AND the trail replays clean.
# Persistence chains stdout → file, like the season/registry.
#
# Build a signed submission (the agent signs, holding its secret):
#   lex run --allow-effects io,crypto examples/agent_registry.lex \
#     sign '"atlas"' '"atlas-seed"' '"robot"' '"robot_task"' '"robot.jsonl"' '"0"' '"false"'
# Fold a signed batch into the registry:
#   lex run --allow-effects io,crypto examples/agent_registry.lex \
#     apply '"none.json"' '"batch.json"' > registry.json

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "../src/identity" as id

import "lex-games/src/arena/reputation" as rep

# A signed submission: the trail plus proof the did's key holder produced it.
type Signed = { did :: Str, pubkey_b64 :: Str, app :: Str, game :: Str, trail :: Str, seat :: Int, won :: Bool, sig :: Str }

# Durable owned reputation. `pubkey_b64` is the key bound to this did; `apps` is
# the distinct apps it earned in; `rejected` counts refused impersonations.
type Profile = { did :: Str, pubkey_b64 :: Str, reputation :: Int, sessions :: Int, wins :: Int, apps :: List[Str], rejected :: Int }

type Prior = { profiles :: List[Profile] }

type Batch = { entries :: List[Signed] }

fn q(s :: Str) -> Str {
  str.join(["\"", s, "\""], "")
}

fn has(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (a :: Bool, s :: Str) -> Bool {
    a or s == x
  })
}

fn add_app(apps :: List[Str], app :: Str) -> List[Str] {
  if has(apps, app) {
    apps
  } else {
    list.concat(apps, [app])
  }
}

# The pubkey a did is already bound to, or "" if this did is new to the registry.
fn bound_key(ps :: List[Profile], did :: Str) -> Str {
  list.fold(ps, "", fn (acc :: Str, p :: Profile) -> Str {
    if p.did == did {
      p.pubkey_b64
    } else {
      acc
    }
  })
}

fn seen(ps :: List[Profile], did :: Str) -> Bool {
  list.fold(ps, false, fn (a :: Bool, p :: Profile) -> Bool {
    a or p.did == did
  })
}

# Credit a verified, signed submission: bind the key on first sight, add the app.
fn credit(ps :: List[Profile], s :: Signed, score :: Int) -> List[Profile] {
  let w := if s.won {
    1
  } else {
    0
  }
  if seen(ps, s.did) {
    list.map(ps, fn (p :: Profile) -> Profile {
      if p.did == s.did {
        { did: p.did, pubkey_b64: p.pubkey_b64, reputation: p.reputation + score, sessions: p.sessions + 1, wins: p.wins + w, apps: add_app(p.apps, s.app), rejected: p.rejected }
      } else {
        p
      }
    })
  } else {
    list.concat(ps, [{ did: s.did, pubkey_b64: s.pubkey_b64, reputation: score, sessions: 1, wins: w, apps: [s.app], rejected: 0 }])
  }
}

# Record a refused submission (impersonation / bad signature) against the did, so
# the attempt is on the record. Never binds a key, never credits.
fn reject(ps :: List[Profile], did :: Str) -> List[Profile] {
  if seen(ps, did) {
    list.map(ps, fn (p :: Profile) -> Profile {
      if p.did == did {
        { did: p.did, pubkey_b64: p.pubkey_b64, reputation: p.reputation, sessions: p.sessions, wins: p.wins, apps: p.apps, rejected: p.rejected + 1 }
      } else {
        p
      }
    })
  } else {
    ps
  }
}

type Acc = { profiles :: List[Profile], credited :: Int, void :: Int, rejected :: Int }

# Fold one signed submission: verify the signature against the did's bound key,
# replay the trail through lex-games, credit only if BOTH hold.
fn fold_one(acc :: Acc, s :: Signed) -> [io, crypto] Acc {
  match io.read(s.trail) {
    Err(_) => { profiles: acc.profiles, credited: acc.credited, void: acc.void + 1, rejected: acc.rejected },
    Ok(content) => {
      let claim := id.claim_of(s.did, s.app, s.game, id.hash_trail(content))
      let bound := bound_key(acc.profiles, s.did)
      let impersonation := if str.is_empty(bound) {
        false
      } else {
        bound != s.pubkey_b64
      }
      if impersonation {
        { profiles: reject(acc.profiles, s.did), credited: acc.credited, void: acc.void, rejected: acc.rejected + 1 }
      } else {
        if not id.verify_claim(s.pubkey_b64, claim, s.sig) {
          { profiles: reject(acc.profiles, s.did), credited: acc.credited, void: acc.void, rejected: acc.rejected + 1 }
        } else {
          let r := rep.replay_entry({ did: s.did, game: s.game, trail: s.trail, seat: s.seat, won: s.won })
          if r.verified {
            { profiles: credit(acc.profiles, s, r.score), credited: acc.credited + 1, void: acc.void, rejected: acc.rejected }
          } else {
            { profiles: acc.profiles, credited: acc.credited, void: acc.void + 1, rejected: acc.rejected }
          }
        }
      }
    },
  }
}

fn ranked(ps :: List[Profile]) -> List[Profile] {
  list.sort_by(ps, fn (p :: Profile) -> Int {
    0 - p.reputation
  })
}

fn apps_json(apps :: List[Str]) -> Str {
  str.join(["[", str.join(list.map(apps, q), ","), "]"], "")
}

fn profile_json(rank :: Int, p :: Profile) -> Str {
  str.join(["{\"rank\":", int.to_str(rank), ",\"did\":", q(p.did), ",\"pubkey_b64\":", q(p.pubkey_b64), ",\"reputation\":", int.to_str(p.reputation), ",\"sessions\":", int.to_str(p.sessions), ",\"wins\":", int.to_str(p.wins), ",\"apps\":", apps_json(p.apps), ",\"rejected\":", int.to_str(p.rejected), "}"], "")
}

type RankAcc = { rank :: Int, parts :: List[Str] }

fn profiles_json(sorted :: List[Profile]) -> Str {
  let acc := list.fold(sorted, { rank: 1, parts: [] }, fn (a :: RankAcc, p :: Profile) -> RankAcc {
    { rank: a.rank + 1, parts: list.concat(a.parts, [profile_json(a.rank, p)]) }
  })
  str.join(acc.parts, ",")
}

fn load_prior(path :: Str) -> [io] List[Profile] {
  match io.read(path) {
    Err(_) => [],
    Ok(content) => {
      let parsed :: Result[Prior, Str] := json.parse(content)
      match parsed {
        Err(_) => [],
        Ok(p) => p.profiles,
      }
    },
  }
}

# ── entrypoints ───────────────────────────────────────────────────────────────
# Build a signed submission from an identity seed and a trail (the agent signs).
fn sign(name :: Str, seed :: Str, app :: Str, game :: Str, trail :: Str, seat_s :: Str, won_s :: Str) -> [io, crypto] Int {
  match id.derive(name, seed) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("derive failed: ", e))
      1
    },
    Ok(ident) => match io.read(trail) {
      Err(e) => {
        let __lex_discard_2 := io.print(str.concat("cannot read trail: ", e))
        1
      },
      Ok(content) => {
        let claim := id.claim_of(ident.did, app, game, id.hash_trail(content))
        match id.sign_claim(ident.secret, claim) {
          Err(e) => {
            let __lex_discard_3 := io.print(str.concat("sign failed: ", e))
            1
          },
          Ok(sig) => {
            let seat := match str.to_int(seat_s) {
              Some(n) => n,
              None => 0,
            }
            let won := won_s == "true"
            let __lex_discard_4 := io.print(str.join(["{\"did\":", q(ident.did), ",\"pubkey_b64\":", q(ident.pubkey_b64), ",\"app\":", q(app), ",\"game\":", q(game), ",\"trail\":", q(trail), ",\"seat\":", int.to_str(seat), ",\"won\":", if won {
              "true"
            } else {
              "false"
            }, ",\"sig\":", q(sig), "}"], ""))
            0
          },
        }
      },
    },
  }
}

# Fold a signed batch ({"entries":[...]}) into the prior registry; print the next.
fn apply(prior_path :: Str, batch_path :: Str) -> [io, crypto] Int {
  let prior := load_prior(prior_path)
  match io.read(batch_path) {
    Err(e) => {
      let __lex_discard_5 := io.print(str.concat("cannot read batch: ", e))
      1
    },
    Ok(content) => {
      let parsed :: Result[Batch, Str] := json.parse(content)
      match parsed {
        Err(e) => {
          let __lex_discard_6 := io.print(str.concat("bad batch json: ", e))
          1
        },
        Ok(b) => {
          let acc := list.fold(b.entries, { profiles: prior, credited: 0, void: 0, rejected: 0 }, fold_one)
          let out := str.join(["{\"profiles\":[", profiles_json(ranked(acc.profiles)), "],\"credited\":", int.to_str(acc.credited), ",\"void\":", int.to_str(acc.void), ",\"rejected\":", int.to_str(acc.rejected), "}"], "")
          let __lex_discard_7 := io.print(out)
          0
        },
      }
    },
  }
}

