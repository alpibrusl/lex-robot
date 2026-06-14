#!/usr/bin/env bash
# Keep the README honest about the code (lex-robot's analog of lex-lang's
# readme_commands.rs / lex-os's cli_reference_is_in_sync): every file path and
# every `make <target>` the README mentions must actually exist. Catches the two
# ways docs rot — a renamed/removed file, or a make target that no longer exists.
# The runtime half (documented demo OUTPUT still holds) is scripts/smoke.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok()  { printf "  \033[32mok\033[0m   %s\n" "$1"; }
bad() { printf "  \033[31mMISSING\033[0m %s\n" "$1"; fail=1; }

echo "== files referenced by README =="
# repo-relative paths (also catches the media/* in raw.githubusercontent URLs)
grep -oE '(examples|sidecar|scripts|src|media|manifests|box)/[A-Za-z0-9_./-]+\.(lex|py|sh|gif|json|md|txt)' README.md \
  | sort -u | while read -r p; do
    [ -e "$p" ] && ok "$p" || bad "$p (referenced in README, not in repo)"
  done

echo "== make targets referenced by README =="
grep -oE 'make [a-z][a-z-]*' README.md | awk '{print $2}' | sort -u | while read -r t; do
    grep -qE "^$t:" Makefile && ok "make $t" || bad "make $t (in README, not in Makefile)"
  done

# the while-loops run in subshells; recompute the verdict from a marker file
# (portable across bash/zsh): re-scan and fail if anything is missing.
miss=0
for p in $(grep -oE '(examples|sidecar|scripts|src|media|manifests|box)/[A-Za-z0-9_./-]+\.(lex|py|sh|gif|json|md|txt)' README.md | sort -u); do
  [ -e "$p" ] || miss=1
done
for t in $(grep -oE 'make [a-z][a-z-]*' README.md | awk '{print $2}' | sort -u); do
  grep -qE "^$t:" Makefile || miss=1
done
echo
if [ "$miss" -eq 0 ]; then echo "README in sync with code"; else echo "README references missing items (above)"; fi
exit "$miss"
