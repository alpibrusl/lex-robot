#!/usr/bin/env bash
# Hardware-enforced run: the robot task as a lex-os Firecracker guest.
#
# Requires: Linux + /dev/kvm + root (jailer) + lex-os assets staged with the
# CURRENT guest baked into the rootfs:
#     cd ../lex-os && sudo bash demo/setup-assets.sh   # rebuilds + injects lex-os-guest
# Re-run setup-assets.sh whenever the guest changes, or the VM boots a stale agent.
#
# This is the REAL boundary (unlike box/sim_e2e.sh's simulated perimeter). The
# robot's outbound effect is sealed behind the kernel egress wall: the guest can
# reach ONLY the allowlisted sidecar address (169.254.42.1:8900).
#
# Sidecar: defaults to the dependency-free sim_sidecar.py so the box proof runs
# on any host (the real-physics gym_sidecar.py needs gym/torch, and run_policy
# SOLVE QUALITY is Issue #2 on a CUDA box). Override with SIDECAR_PY=gym_sidecar.py.
#
# Usage: sudo ./box/run_in_vm.sh [robot-demo|robot-violation]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXOS="$ROOT/../lex-os"
M="$ROOT/manifests/pick_place.capsule.json"
AUDIT=/tmp/robot-audit.json
TRAIL=/tmp/robot-trail.json
SCRIPT="${1:-robot-demo}"
SIDECAR_PY="${SIDECAR_PY:-sim_sidecar.py}"

# Clear stale outputs so a failed run can NEVER reconcile against old data
# (a previous version silently passed by reading a prior run's files).
rm -f "$AUDIT" "$TRAIL"

# Sidecar must be reachable from inside the guest at 169.254.42.1:8900 → bind 0.0.0.0.
cd "$ROOT"
LEX_ROBOT_SIDECAR_HOST=0.0.0.0 LEX_ROBOT_TRAIL="$TRAIL" \
  python3 "sidecar/$SIDECAR_PY" >/tmp/robot-sidecar.log 2>&1 & SIDECAR=$!
trap 'kill $SIDECAR 2>/dev/null || true' EXIT
sleep 3
if ! kill -0 "$SIDECAR" 2>/dev/null; then
  echo "ERROR: sidecar ($SIDECAR_PY) failed to start:"; tail -5 /tmp/robot-sidecar.log; exit 1
fi

cd "$LEXOS"
# --jail-uid/--jail-gid run firecracker under the jailer; the kvm gid lets the
# guest reach /dev/kvm. The guest binary is baked into the rootfs by setup-assets.sh.
"$LEXOS"/target/debug/lex-os run \
  --manifest "$M" --agent robot --guest-script "$SCRIPT" \
  --jail-uid "$(id -u)" --jail-gid "$(getent group kvm | cut -d: -f3)" \
  --audit-out "$AUDIT"

# Fail loudly if the run didn't actually produce fresh outputs this time.
[ -s "$AUDIT" ] || { echo "ERROR: no audit log at $AUDIT (run did not write it)"; exit 1; }
[ -s "$TRAIL" ] || { echo "ERROR: no sidecar trail at $TRAIL (guest never reached the sidecar — check the egress wall / sidecar bind)"; exit 1; }

echo "== reconcile =="
python3 "$ROOT/scripts/reconcile_audit.py" "$AUDIT" "$TRAIL"
