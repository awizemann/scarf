#!/usr/bin/env bash
#
# Verify ScarfGo's SSH host-key pinning against a REAL sshd: first connect
# pins silently, a swapped host key is refused by every Citadel funnel
# (transport, ACP chat, Test Connection) with HostKeyMismatchError, and a
# re-trust pins the new key.
#
# Self-contained: an ephemeral, localhost-only sshd on a high port with two
# throwaway host keys (NO system Remote Login, no sudo), torn down on exit.
#
# Usage: ./scripts/verify-ios-host-key-pinning.sh
set -euo pipefail

PORT="${SCARF_VERIFY_PORT:-2223}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t scarf-hostkey)"

cleanup() {
  if [[ -f "$WORK/sshd.pid" ]]; then kill "$(cat "$WORK/sshd.pid")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -t ed25519 -f "$WORK/host_a" -N "" -q -C host-a
ssh-keygen -t ed25519 -f "$WORK/host_b" -N "" -q -C host-b
chmod 600 "$WORK/host_a" "$WORK/host_b"
: > "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys"
FP_A="$(ssh-keygen -lf "$WORK/host_a.pub" | awk '{print $2}')"
FP_B="$(ssh-keygen -lf "$WORK/host_b.pub" | awk '{print $2}')"

write_config() {  # $1 = host key file, $2 = config path
  cat > "$2" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $1
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
EOF
}
write_config "$WORK/host_a" "$WORK/sshd_a"
write_config "$WORK/host_b" "$WORK/sshd_b"

echo "==> sshd on 127.0.0.1:$PORT with host key A ($FP_A)"
/usr/sbin/sshd -f "$WORK/sshd_a" -E "$WORK/sshd.log"
sleep 1

SWAP="kill \$(cat '$WORK/sshd.pid'); sleep 1; /usr/sbin/sshd -f '$WORK/sshd_b' -E '$WORK/sshd.log'; sleep 1"

echo "==> running HostKeyPinningLiveTests (host key B is $FP_B)"
SCARF_LIVE_HK_PORT="$PORT" \
SCARF_LIVE_HK_USER="$(whoami)" \
SCARF_LIVE_HK_AUTHORIZED_KEYS="$WORK/authorized_keys" \
SCARF_LIVE_HK_FP_A="$FP_A" \
SCARF_LIVE_HK_FP_B="$FP_B" \
SCARF_LIVE_HK_SWAP="$SWAP" \
  swift test --package-path "$REPO/scarf/Packages/ScarfIOS" --filter HostKeyPinningLiveTests

echo "==> done"
