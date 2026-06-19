#!/usr/bin/env bash
# Hardware-enforced run: the robot task as a lex-os Firecracker guest.
#
# Requires: Linux + /dev/kvm + root (jailer) + assets (lex-os demo/setup-assets.sh)
# + the gym sidecar running on the host bound to the tap-side IP.
#
# This is the REAL boundary (unlike box/sim_e2e.sh, which uses the simulated
# perimeter). The robot's outbound effect is sealed behind the kernel egress
# wall: the guest can reach ONLY the allowlisted sidecar address (10.0.2.2:8900).
#
# The policy SOLVE QUALITY (run_policy actually solving PushT) is Issue #2 on a
# CUDA box; this run proves mediation + execution + audit + reconcile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXOS="$ROOT/../lex-os"
M="$ROOT/manifests/pick_place.capsule.json"
AUDIT=/tmp/robot-audit.json
TRAIL=/tmp/robot-trail.json
SCRIPT="${1:-robot-demo}"   # or: robot-violation

# The sidecar must be reachable from inside the guest at 10.0.2.2:8900, so bind
# it to 0.0.0.0 on the host. Use the real-physics gym backend here (the hardware
# run is where the real env matters); swap to sim_sidecar.py to test wiring only.
cd "$ROOT"
LEX_ROBOT_SIDECAR_HOST=0.0.0.0 LEX_ROBOT_TRAIL="$TRAIL" \
  python3 sidecar/gym_sidecar.py & SIDECAR=$!
trap 'kill $SIDECAR 2>/dev/null || true' EXIT
sleep 10   # gym-pusht env warmup

cd "$LEXOS"
# --jail-uid/--jail-gid run firecracker under the jailer; the kvm gid lets the
# guest reach /dev/kvm. The guest binary (musl + vsock) is injected by the
# perimeter — build it first with:
#   cargo build -p lex-os-guest --target x86_64-unknown-linux-musl --features vsock
sudo -E "$LEXOS"/target/debug/lex-os run \
  --manifest "$M" --agent robot --guest-script "$SCRIPT" \
  --jail-uid "$(id -u)" --jail-gid "$(getent group kvm | cut -d: -f3)" \
  --audit-out "$AUDIT"

echo "== reconcile =="
python3 "$ROOT/scripts/reconcile_audit.py" "$AUDIT" "$TRAIL"
