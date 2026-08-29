#!/usr/bin/env bash
# Print the OpenCode Go catalogue as the API actually reports it.
#
# The plan's advertised names (GLM-5.1, Kimi K2.6, ...) are marketing names and
# are not reliably the API ids you must put in config.yaml. This asks the
# endpoint, which is the only authority. OpenCode also rotates the catalogue,
# so re-run it when a model starts 404ing.
#
#   ~/litellm/list-opencode-models.sh
#
# Reads the key from OPENCODE_API_KEY, or ~/.credentials/oc.key (this unit's
# location). The key is never echoed, and must never be committed.
set -euo pipefail

KEY="${OPENCODE_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HOME/.credentials/oc.key" ]; then
  KEY="$(tr -d '[:space:]' < "$HOME/.credentials/oc.key")"
fi
if [ -z "$KEY" ]; then
  cat >&2 <<'EOF'
No OpenCode key found.

Put it in place WITHOUT pasting it into a chat or a shell history:

  mkdir -p ~/.credentials
  (umask 077; cat > ~/.credentials/oc.key)   # paste the key, then Ctrl-D

Get the key from https://opencode.ai/auth
EOF
  exit 1
fi

for base in "https://opencode.ai/zen/go/v1" "https://opencode.ai/zen/v1"; do
  echo "== $base/models =="
  code=$(curl -s -o /tmp/oc_models.$$ -w '%{http_code}' -H "Authorization: Bearer $KEY" "$base/models" || echo 000)
  if [ "$code" = "200" ]; then
    python3 -c "
import json,sys
d=json.load(open('/tmp/oc_models.$$'))
rows=d.get('data', d if isinstance(d,list) else [])
if not rows:
    print('  (200 but no model list in the response)'); sys.exit()
for m in rows:
    mid = m.get('id') or m.get('name') or '?'
    extra = [str(m[k]) for k in ('owned_by','description') if m.get(k)]
    print('  ' + mid + ('   # ' + ' | '.join(extra) if extra else ''))
print(f'\n  {len(rows)} model(s)')
" 2>/dev/null || { echo "  (unparseable response)"; head -c 300 /tmp/oc_models.$$; echo; }
  else
    echo "  HTTP $code"
    [ -s /tmp/oc_models.$$ ] && head -c 200 /tmp/oc_models.$$ && echo
  fi
  rm -f /tmp/oc_models.$$
  echo
done

cat <<'EOF'
Next: copy the ids you want into ~/litellm/config.yaml under `model:` as
`openai/<id>`, then restart the proxy.

Reminder: everything on the Go plan is a TEXT coding model. Do not route
camera frames here — use the `vision` entry (Ollama on the Mac Studio).
EOF
