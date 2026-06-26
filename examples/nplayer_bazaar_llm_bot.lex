# examples/nplayer_bazaar_llm_bot.lex — an LLM-driven agent for the N-player
# Bazaar Draft referee (examples/nplayer_bazaar.lex). Same wire protocol as the
# heuristic nplayer_bazaar_bot.lex, but on its turn it asks a hosted open-weights
# model (OpenCode Zen "Go plan") which item to draft. Point several of these at
# one referee with different BOT_MODELs for a live multi-model free-for-all.
#
# The model's answer is validated locally (must be an unowned, affordable item);
# an illegal or garbage reply falls back to a greedy-by-value pick (or pass), so
# a weak model loses points but can never stall the referee.
#
# Env: NB_PORT (referee port, default 8902)
#      BOT_MODEL (opencode-go model id, default glm-5.1)
#      OPENCODE_API_KEY (required — the Zen Go-plan key)
# Run: BOT_MODEL=kimi-k2.6 OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#        lex run --allow-effects env,net,concurrent,io,llm,proc \
#        examples/nplayer_bazaar_llm_bot.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.iter" as iter

import "std.net" as net

import "std.conc" as conc

import "std.tuple" as tup

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/openai" as oai

fn budget() -> Int {
  30
}

fn opencode_zen_url() -> Str {
  "https://opencode.ai/zen/go/v1/chat/completions"
}

# ── memory: just the server-assigned seat id ─────────────────────────────────
type Bot = { myid :: Str }

type Msg = Line(Str)

# pool entry "price/value/owner" → Entry
type Entry = { price :: Int, value :: Int, owner :: Str }

fn parse_entry(e :: Str) -> Entry {
  let parts := str.split(e, "/")
  { price: to_i(nth_str(parts, 0)), value: to_i(nth_str(parts, 1)), owner: nth_str(parts, 2) }
}

fn nth_str(xs :: List[Str], i :: Int) -> Str {
  let r := list.fold(xs, (0, ""), fn (acc :: (Int, Str), x :: Str) -> (Int, Str) {
    if tup.fst(acc) == i {
      (tup.fst(acc) + 1, x)
    } else {
      (tup.fst(acc) + 1, tup.snd(acc))
    }
  })
  tup.snd(r)
}

fn to_i(s :: Str) -> Int {
  match str.to_int(str.trim(s)) {
    Some(n) => n,
    None => 0,
  }
}

# pull "key=val" token value out of the STATE line
fn field(s :: Str, key :: Str) -> Str {
  list.fold(str.split(s, " "), "", fn (acc :: Str, tok :: Str) -> Str {
    if str.starts_with(tok, key) {
      str.slice(tok, str.len(key), str.len(tok))
    } else {
      acc
    }
  })
}

# text between the first '[' after `after` and the next ']'
fn bracket(s :: Str, after :: Str) -> Str {
  let tail := snd_split(s, after)
  let inside := snd_split(tail, "[")
  list.fold(str.split(inside, "]"), "", fn (acc :: Str, seg :: Str) -> Str {
    if str.is_empty(acc) {
      seg
    } else {
      acc
    }
  })
}

fn snd_split(s :: Str, sep :: Str) -> Str {
  let parts := str.split(s, sep)
  if list.len(parts) >= 2 {
    nth_str(parts, 1)
  } else {
    s
  }
}

# how much I've spent = sum of prices of pool entries I own
fn my_spend(pool :: Str, myid :: Str) -> Int {
  list.fold(str.split(pool, ","), 0, fn (s :: Int, e :: Str) -> Int {
    let it := parse_entry(e)
    if it.owner == myid {
      s + it.price
    } else {
      s
    }
  })
}

# ── heuristic fallback (greedy by value): used when the LLM picks illegally ───
type Pick = { idx :: Int, best_i :: Int, best_s :: Int }

fn heuristic(pool :: Str, my_spent :: Int) -> Int {
  let r := list.fold(str.split(pool, ","), { idx: 0, best_i: 0 - 1, best_s: 0 - 1 }, fn (acc :: Pick, e :: Str) -> Pick {
    let it := parse_entry(e)
    let ok := str.is_empty(it.owner) and my_spent + it.price <= budget()
    if ok and it.value > acc.best_s {
      { idx: acc.idx + 1, best_i: acc.idx, best_s: it.value }
    } else {
      { idx: acc.idx + 1, best_i: acc.best_i, best_s: acc.best_s }
    }
  })
  r.best_i
}

# is item index `i` a legal draft (unowned + affordable) for me right now?
fn legal(pool :: Str, i :: Int, my_spent :: Int) -> Bool {
  let r := list.fold(str.split(pool, ","), (0, false), fn (acc :: (Int, Bool), e :: Str) -> (Int, Bool) {
    let it := parse_entry(e)
    let hit := tup.fst(acc) == i and str.is_empty(it.owner) and my_spent + it.price <= budget()
    (tup.fst(acc) + 1, tup.snd(acc) or hit)
  })
  tup.snd(r)
}

# ── prompt + reply parsing ───────────────────────────────────────────────────
fn list_items(pool :: Str, my_spent :: Int) -> Str {
  let r := list.fold(str.split(pool, ","), (0, ""), fn (acc :: (Int, Str), e :: Str) -> (Int, Str) {
    let it := parse_entry(e)
    let tag := if not str.is_empty(it.owner) {
      "TAKEN"
    } else {
      if my_spent + it.price <= budget() {
        "affordable"
      } else {
        "too expensive"
      }
    }
    let line := str.join(["  ", int.to_str(tup.fst(acc)), ": cost ", int.to_str(it.price), ", worth ", int.to_str(it.value), " (", tag, ")\n"], "")
    (tup.fst(acc) + 1, str.join([tup.snd(acc), line], ""))
  })
  tup.snd(r)
}

fn build_prompt(pool :: Str, my_spent :: Int) -> Str {
  str.join(["It is your turn in the Bazaar draft. Budget is ", int.to_str(budget()), " credits; you have already spent ", int.to_str(my_spent), " (so ", int.to_str(budget() - my_spent), " left).\n\nItems (index: cost, worth):\n", list_items(pool, my_spent), "\nDraft ONE item you can afford to maximise your own total worth, or pass if nothing is worth it.\n", "Reply with EXACTLY one line: PICK:<index>  or  PICK:PASS"], "")
}

fn extract_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m {
        AssistantMsg(text, _) => text,
        _ => acc,
      },
      _ => acc,
    }
  })
}

# returns chosen index, -2 for explicit PASS, or -1 for none/garbage
fn parse_pick(text :: Str) -> Int {
  let lo := str.to_lower(text)
  list.fold(str.split(lo, "\n"), 0 - 1, fn (acc :: Int, line :: Str) -> Int {
    match str.strip_prefix(str.trim(line), "pick:") {
      None => acc,
      Some(rest) => {
        let r := str.trim(rest)
        if str.starts_with(r, "pass") {
          0 - 2
        } else {
          match str.to_int(r) {
            Some(n) => n,
            None => acc,
          }
        }
      },
    }
  })
}

# Turn the model's pick into a referee command, repairing illegal answers.
fn to_command(pool :: Str, my_spent :: Int, pick :: Int) -> Str {
  if pick == 0 - 2 {
    "pass"
  } else {
    if pick >= 0 and legal(pool, pick, my_spent) {
      str.join(["draft ", int.to_str(pick)], "")
    } else {
      let h := heuristic(pool, my_spent)
      if h >= 0 {
        str.join(["draft ", int.to_str(h)], "")
      } else {
        "pass"
      }
    }
  }
}

# The mind actor only tracks the seat id and, on our turn, hands back the
# context the LLM needs: "TURN <pool> <my_spent>" (pool has no spaces).
fn mind_step(b :: Bot, line :: Str) -> (Bot, Str) {
  if str.starts_with(line, "YOU ") {
    ({ myid: str.trim(str.slice(line, 4, str.len(line))) }, "")
  } else {
    if str.starts_with(line, "STATE") {
      let started := field(line, "started=") == "1"
      let over := field(line, "over=") == "1"
      let turn := field(line, "turn=")
      if not started or over or turn != b.myid or str.is_empty(b.myid) {
        (b, "")
      } else {
        let pool := bracket(line, "pool=")
        (b, str.join(["TURN ", pool, " ", int.to_str(my_spend(pool, b.myid))], ""))
      }
    } else {
      (b, "")
    }
  }
}

fn run() -> [env, net, concurrent, io, llm, proc] Nil {
  let port := match env.get("NB_PORT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8902,
    },
    None => 8902,
  }
  let model_name := match env.get("BOT_MODEL") {
    Some(v) => v,
    None => "glm-5.1",
  }
  let key := match env.get("OPENCODE_API_KEY") {
    Some(v) => v,
    None => "",
  }
  if str.is_empty(key) {
    io.print("[llm-bot] OPENCODE_API_KEY is required")
  } else {
    let url := str.join(["ws://127.0.0.1:", int.to_str(port)], "")
    let provider := oai.make_provider({ api_key: key, base_url: opencode_zen_url() })
    let model := prov.make_model_ref("opencode-go", model_name)
    let opts := { temperature: Some(0.3), top_p: None, max_steps: Some(1), max_tokens: Some(2500) }
    let system := str.join(["You are a sharp, competitive player in an N-player Bazaar draft. ", "Players take turns claiming items from a shared pool under a fixed budget; ", "the highest total worth wins. On your turn you draft exactly one item you ", "can afford. Think about value for money. Always answer with EXACTLY one ", "line: PICK:<index> or PICK:PASS, nothing else."], "")
    let agent := llm_agent.make_agent("bazaar-llm", system, model, provider, [], opts)
    let mind := conc.spawn({ myid: "" }, fn (b :: Bot, m :: Msg) -> (Bot, Str) {
      match m {
        Line(s) => mind_step(b, s),
      }
    })
    let __lex_discard_1 := io.print(str.join(["[llm-bot] dialing ", url, " model=", model_name], ""))
    let res := net.dial_ws(url, "", fn () -> [concurrent, io, llm, net, proc] WsAction {
      WsSend("join")
    }, fn (m :: WsMessage) -> [concurrent, io, llm, net, proc] WsAction {
      match m {
        WsText(s) => {
          let resp := conc.ask(mind, Line(s))
          if str.starts_with(resp, "TURN ") {
            let rest := str.slice(resp, 5, str.len(resp))
            let parts := str.split(rest, " ")
            let pool := nth_str(parts, 0)
            let spent := to_i(nth_str(parts, 1))
            let steps := iter.to_list(llm_agent.run_loop(agent, [UserMsg(build_prompt(pool, spent))]))
            let text := extract_text(steps)
            let cmd := to_command(pool, spent, parse_pick(text))
            let __lex_discard_2 := io.print(str.join(["[llm-bot ", model_name, "] turn → ", cmd, "   (said: ", str.trim(text), ")"], ""))
            WsSend(cmd)
          } else {
            WsNoOp
          }
        },
        _ => WsNoOp,
      }
    })
    match res {
      Ok(_) => io.print("[llm-bot] closed"),
      Err(e) => io.print(str.join(["[llm-bot] error: ", e], "")),
    }
  }
}

