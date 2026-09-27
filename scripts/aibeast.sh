#!/bin/bash
# aibeast.sh — run a command on the aibeast Mac Studio (aiserver.home / 192.168.30.10).
#
# Auth:
#   1. tries the homelab SSH key (passwordless), else
#   2. falls back to AIBEAST_USER / AIBEAST_PASS from Infisical via expect.
#
# Usage:
#   ./scripts/aibeast.sh 'docker ps -a'
#   ./scripts/aibeast.sh --install-key
#   echo 'docker ps' | ./scripts/aibeast.sh -
#
# The command is base64-encoded and decoded remotely, so quoting/redirection
# work exactly as written.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${AIBEAST_HOST:-192.168.30.10}"
KEY="${AIBEAST_KEY:-$HOME/.ssh/homelab-agent-util-server}"
SSH_BASE="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

resolve_cmd() {
  if [ "${1:-}" = "-" ]; then cat; else printf '%s' "${1:-}"; fi
}

install_key() {
  local pub; pub="$(cat "$KEY.pub")"
  local cmd
  cmd=$(cat <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys
echo "KEY_INSTALLED"
EOF
)
  run_with_password "$cmd"
}

run_with_password() { # $1 = shell script
  local b64 expect_script
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  expect_script=$(cat <<EXP
set timeout 30
set user \$env(AIBEAST_USER)
set pw \$env(AIBEAST_PASS)
spawn ssh $SSH_BASE -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \$user@$HOST {echo $b64 | base64 -D | /bin/zsh -s}
expect {
  -re "(?i)password:" { send "\$pw\r"; exp_continue }
  "Permission denied" { puts "\\n>>> auth denied"; exit 3 }
  timeout { puts "\\n>>> timeout"; exit 5 }
  eof
}
EXP
)
  expect -c "$expect_script"
}

# load creds if we might need them
load_creds() {
  # shellcheck disable=SC1091
  source "$REPO/scripts/infisical-agent.sh" >/dev/null 2>&1
  AIBEAST_USER="$(infs get AIBEAST_USER 2>/dev/null)"
  AIBEAST_PASS="$(infs get AIBEAST_PASS 2>/dev/null)"
  export AIBEAST_USER AIBEAST_PASS
}

if [ "${1:-}" = "--install-key" ]; then
  load_creds
  [ -n "$AIBEAST_USER" ] || { echo "AIBEAST_USER missing from Infisical" >&2; exit 1; }
  install_key
  echo "Now testing key auth ..."
  if ssh $SSH_BASE -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$AIBEAST_USER@$HOST" 'echo KEY_AUTH_OK'; then
    echo "Passwordless access ready."
  fi
  exit 0
fi

[ "$#" -ge 1 ] || usage

load_creds
[ -n "$AIBEAST_USER" ] || { echo "AIBEAST_USER missing from Infisical" >&2; exit 1; }
CMD="$(resolve_cmd "$@")"
B64="$(printf '%s' "$CMD" | base64 | tr -d '\n')"

# Prefer passwordless key auth when it already works.
if ssh $SSH_BASE -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
     "$AIBEAST_USER@$HOST" true 2>/dev/null; then
  ssh $SSH_BASE -i "$KEY" -o IdentitiesOnly=yes \
    "$AIBEAST_USER@$HOST" "echo $B64 | base64 -D | /bin/zsh -s"
else
  run_with_password "$CMD"
fi
