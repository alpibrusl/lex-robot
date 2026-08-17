# src/llm_provider.lex — one seam for "which model plans the robot".
#
# The planner (src/llm_planner.lex) takes a Provider + ModelRef and does not
# care where they came from; this module is the ONE place that decides, from
# the environment, so every LLM-driven entry point offers the same choices:
#
#   LEX_LLM_PROVIDER   ollama   — local Ollama, native /api/chat, NO API key.
#                                 The local-first default: the same Mac
#                                 Studio that judges vision frames
#                                 (deploy/VISION_SPLIT.md) plans the robot.
#                      openai   — any OpenAI-compatible chat-completions
#                                 endpoint: a LiteLLM proxy, OpenAI itself,
#                                 Azure. Point LEX_LLM_URL at it.
#                      opencode — OpenCode Zen's Go plan (the previous
#                                 default), needs an API key.
#   LEX_LLM_URL        chat endpoint override (per-provider default below)
#   LEX_LLM_MODEL      model name (per-provider default below)
#   LEX_LLM_API_KEY    bearer key for openai/opencode (LiteLLM proxies
#                      commonly run keyless — empty is allowed for openai,
#                      refused for opencode where a key is always required;
#                      OPENCODE_API_KEY is honored as a fallback spelling)
#
# With LEX_LLM_PROVIDER unset: OPENCODE_API_KEY present selects opencode
# (compatibility with the existing `make xlerobot-llm`), otherwise ollama —
# local-first, so a fresh checkout with a running Ollama plans with no
# cloud key at all.

import "std.str" as str

import "std.env" as env

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/ollama" as oll

import "lex-llm/src/providers/openai" as oai

# What from_env resolved: ready to hand to llm_planner.plan.
type Selected = { provider :: prov.Provider, model :: prov.ModelRef, label :: Str }

fn opencode_zen_url() -> Str {
  "https://opencode.ai/zen/go/v1/chat/completions"
}

# Per-provider default chat endpoint. The openai default is a LOCAL LiteLLM
# proxy on its standard port — the split-compute posture — not api.openai.com;
# point LEX_LLM_URL at whichever OpenAI-compatible endpoint you actually run.
fn default_url(name :: Str) -> Str
  examples {
    default_url("ollama") => "http://localhost:11434/api/chat",
    default_url("openai") => "http://localhost:4000/v1/chat/completions",
    default_url("opencode") => "https://opencode.ai/zen/go/v1/chat/completions",
    default_url("nope") => ""
  }
{
  if name == "ollama" {
    "http://localhost:11434/api/chat"
  } else {
    if name == "openai" {
      "http://localhost:4000/v1/chat/completions"
    } else {
      if name == "opencode" {
        opencode_zen_url()
      } else {
        ""
      }
    }
  }
}

# Per-provider default model. qwen2.5 is a small local model with solid
# tool-calling; the opencode default matches llm_planner's documented
# caveat about that catalog moving fast.
fn default_model_name(name :: Str) -> Str
  examples {
    default_model_name("ollama") => "qwen2.5",
    default_model_name("openai") => "gpt-4o-mini",
    default_model_name("opencode") => "kimi-k2.6",
    default_model_name("nope") => ""
  }
{
  if name == "ollama" {
    "qwen2.5"
  } else {
    if name == "openai" {
      "gpt-4o-mini"
    } else {
      if name == "opencode" {
        "kimi-k2.6"
      } else {
        ""
      }
    }
  }
}

# Build the Provider + ModelRef for explicit settings. Pure construction —
# selection behavior is pinned by from_env's defaults above; Provider is a
# closure record, so vectors live on default_url/default_model_name instead.
fn select(name :: Str, url :: Str, model_name :: Str, api_key :: Str) -> Result[Selected, Str] {
  let label := str.join([name, "/", model_name, " @ ", url], "")
  if name == "ollama" {
    Ok({ provider: oll.make_provider({ base_url: url }), model: prov.make_model_ref("ollama", model_name), label: label })
  } else {
    if name == "openai" {
      Ok({ provider: oai.make_provider({ api_key: api_key, base_url: url }), model: prov.make_model_ref("openai", model_name), label: label })
    } else {
      if name == "opencode" {
        if str.is_empty(api_key) {
          Err("opencode needs an API key — set LEX_LLM_API_KEY or OPENCODE_API_KEY (opencode.ai/zen)")
        } else {
          Ok({ provider: oai.make_provider({ api_key: api_key, base_url: url }), model: prov.make_model_ref("opencode-go", model_name), label: label })
        }
      } else {
        Err(str.join(["unknown LEX_LLM_PROVIDER '", name, "' — use ollama | openai | opencode"], ""))
      }
    }
  }
}

fn env_or(key :: Str, dflt :: Str) -> [env] Str {
  match env.get(key) {
    None => dflt,
    Some(v) => if str.is_empty(v) {
      dflt
    } else {
      v
    },
  }
}

# Resolve the planner's provider from the environment (defaults documented
# in the module header).
fn from_env() -> [env] Result[Selected, Str] {
  let opencode_key := env_or("OPENCODE_API_KEY", "")
  let name := match env.get("LEX_LLM_PROVIDER") {
    Some(v) => if str.is_empty(v) {
      fallback_name(opencode_key)
    } else {
      v
    },
    None => fallback_name(opencode_key),
  }
  let url := env_or("LEX_LLM_URL", default_url(name))
  let model_name := env_or("LEX_LLM_MODEL", env_or("OPENCODE_MODEL", default_model_name(name)))
  let api_key := env_or("LEX_LLM_API_KEY", opencode_key)
  select(name, url, model_name, api_key)
}

# LEX_LLM_PROVIDER unset: an OpenCode key keeps the old behavior; otherwise
# local-first.
fn fallback_name(opencode_key :: Str) -> Str
  examples {
    fallback_name("") => "ollama",
    fallback_name("sk-live") => "opencode"
  }
{
  if str.is_empty(opencode_key) {
    "ollama"
  } else {
    "opencode"
  }
}

