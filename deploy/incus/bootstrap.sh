#!/usr/bin/env bash
# HAPI Incus runner bootstrap — parameterized, runs on ANY runner host.
#
# Builds a "golden" runner image once from cloud-init.runner.yaml, then launches
# and provisions ONE runner from env/args. Run once per host:
#
#   netcup  (hapi-personal-runner, same host as the hub):
#     RUNNER_NAME=hapi-personal-runner WORKSPACE_VOL=personal-workspace \
#     HAPI_API_URL=http://10.236.0.1:3006 bash deploy/incus/bootstrap.sh
#
#   devnode (ir-devnode-ryan, reaches the hub via the tunnel):
#     RUNNER_NAME=hapi-work-runner WORKSPACE_VOL=work-workspace \
#     HAPI_API_URL=https://hapi.jkryanchou.com bash deploy/incus/bootstrap.sh
#
# HAPI_TOKEN is read from $ENV_FILE (default ~/deploy/.env) or the environment.
# Agent creds are pushed from the INVOKING host's $HOME; missing files are skipped
# (authenticate agents on the host first, or push later and restart the runner).
#
# Prereqs (one-time host setup):
#   sudo apt update && sudo apt install -y incus btrfs-progs
#   sudo adduser "$USER" incus-admin   # re-login afterwards
#   sudo incus admin init             # storage=btrfs; bridge=incusbr0
#   # On a host that ALSO runs Docker (netcup): DOCKER-USER ACCEPT rules for
#   # incusbr0 — see deploy/incus/README.md. Not needed on Docker-free hosts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

# ── Required parameters ───────────────────────────────────────────────────────
RUNNER_NAME="${RUNNER_NAME:-${1:-}}"
WORKSPACE_VOL="${WORKSPACE_VOL:-${2:-}}"
HAPI_API_URL="${HAPI_API_URL:-${3:-}}"
HAPI_TOKEN="${HAPI_TOKEN:-${4:-}}"
: "${RUNNER_NAME:?set RUNNER_NAME (e.g. hapi-personal-runner)}"
: "${WORKSPACE_VOL:?set WORKSPACE_VOL (e.g. personal-workspace)}"
: "${HAPI_API_URL:?set HAPI_API_URL (full URL, e.g. http://10.236.0.1:3006 or https://hapi.jkryanchou.com)}"
: "${HAPI_TOKEN:?set HAPI_TOKEN in $ENV_FILE or the environment}"

# ── 1. Profile (cloud-init injected from the committed file) ──────────────────
if ! incus profile show hapi-runner >/dev/null 2>&1; then
  incus profile create hapi-runner
fi
incus profile set    hapi-runner security.nesting=true   # allow docker-in-container
incus profile set    hapi-runner cloud-init.vendor-data - < "$HERE/cloud-init.runner.yaml"
incus profile device add hapi-runner eth0 nic network=incusbr0 name=eth0 2>/dev/null || true
incus profile device add hapi-runner root disk pool=default path=/      2>/dev/null || true

# ── 2. Build the golden image once ────────────────────────────────────────────
if ! incus image alias list | grep -q hapi-runner-golden; then
  incus launch images:ubuntu/24.04/cloud hapi-runner-build --profile hapi-runner
  # cloud-init status --wait can return before runcmd finishes; poll explicitly.
  incus exec hapi-runner-build -- bash -lc 'until cloud-init status | grep -qE "done|error"; do sleep 5; done'
  incus exec hapi-runner-build -- bash -lc 'claude --version && codex --version && gemini --version && opencode --version'
  incus stop   hapi-runner-build
  incus publish hapi-runner-build --alias hapi-runner-golden
  incus delete hapi-runner-build
fi

# ── 3. Launch + provision the runner ──────────────────────────────────────────
incus storage volume create default "$WORKSPACE_VOL" 2>/dev/null || true
if ! incus info "$RUNNER_NAME" >/dev/null 2>&1; then
  incus launch hapi-runner-golden "$RUNNER_NAME" --profile hapi-runner
  incus config device add "$RUNNER_NAME" workspace disk pool=default source="$WORKSPACE_VOL" path=/workspace
fi

# Agent creds — pushed from the INVOKING host's $HOME. Missing files are skipped.
[ -d "$HOME/.claude" ] && incus file push -r "$HOME/.claude" "$RUNNER_NAME/root/.claude"
[ -d "$HOME/.gemini" ] && incus file push -r "$HOME/.gemini" "$RUNNER_NAME/root/.gemini"
[ -f "$HOME/.codex/auth.json" ] && \
  incus file push "$HOME/.codex/auth.json" "$RUNNER_NAME/root/.codex/auth.json"
[ -f "$HOME/.local/share/opencode/auth.json" ] && \
  incus file push "$HOME/.local/share/opencode/auth.json" \
                  "$RUNNER_NAME/root/.local/share/opencode/auth.json"

# Hub link + token (consumed by the systemd unit AND interactive login shells).
printf 'HAPI_API_URL=%s\nCLI_API_TOKEN=%s\n' "$HAPI_API_URL" "$HAPI_TOKEN" \
  | incus file push - "$RUNNER_NAME/etc/hapi.env"
incus exec "$RUNNER_NAME" -- systemctl enable --now hapi-runner
echo "OK: $RUNNER_NAME -> $HAPI_API_URL"

cat <<EOF

Verify:
  incus list
  incus exec $RUNNER_NAME -- systemctl status hapi-runner
  incus exec $RUNNER_NAME -- journalctl -u hapi-runner -n 20 --no-pager

Scenario B (interactive agent shell):
  incus exec $RUNNER_NAME -t --cwd /workspace -- bash -lc 'hapi codex'
EOF
