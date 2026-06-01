#!/usr/bin/env bash
# HAPI Incus runner bootstrap — run on the netcup host (Debian 13 / trixie).
#
# Builds a "golden" runner image once from cloud-init.runner.yaml, then clones
# it into the two real runners (personal + work) and provisions their secrets.
#
# Prereqs (one-time host setup):
#   sudo apt update && sudo apt install -y incus btrfs-progs
#   sudo adduser "$USER" incus-admin   # re-login afterwards
#   sudo incus admin init             # storage=btrfs, bridge=incusbr0 (10.236.0.1/24)
#   # Docker<->Incus firewall: add {"ip-forward-no-drop": true} to
#   # /etc/docker/daemon.json and `sudo systemctl restart docker`.
#
# Secrets are read from the SAME ~/deploy/.env used by docker-compose, plus the
# local credential files on the host (~/.codex, ~/.local/share/opencode, etc.).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/deploy/.env}"
GW="${INCUS_GW:-10.236.0.1}"            # incusbr0 gateway = host, where hubs publish
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

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
  incus exec hapi-runner-build -- cloud-init status --wait
  incus exec hapi-runner-build -- bash -lc 'claude --version && codex --version && gemini --version && opencode --version'
  incus stop   hapi-runner-build
  incus publish hapi-runner-build --alias hapi-runner-golden
  incus delete hapi-runner-build
fi

# ── 3. Launch + provision one runner ─────────────────────────────────────────
# usage: launch_runner <name> <workspace-vol> <hub-port> <token>
launch_runner() {
  local name="$1" vol="$2" port="$3" token="$4"
  incus storage volume create default "$vol" 2>/dev/null || true
  if ! incus info "$name" >/dev/null 2>&1; then
    incus launch hapi-runner-golden "$name" --profile hapi-runner
    # --device at launch can only override existing profile devices; add workspace after
    incus config device add "$name" workspace disk pool=default source="$vol" path=/workspace
  fi
  # Static creds (read-only is fine)
  [ -d "$HOME/.claude" ] && incus file push -r "$HOME/.claude" "$name/root/.claude"
  [ -d "$HOME/.gemini" ] && incus file push -r "$HOME/.gemini" "$name/root/.gemini"
  # Codex (ChatGPT OAuth) + opencode auth — writable, just push the JSON
  [ -f "$HOME/.codex/auth.json" ] && \
    incus file push "$HOME/.codex/auth.json" "$name/root/.codex/auth.json"
  [ -f "$HOME/.local/share/opencode/auth.json" ] && \
    incus file push "$HOME/.local/share/opencode/auth.json" \
                    "$name/root/.local/share/opencode/auth.json"
  # Hub link + token (consumed by the systemd unit AND interactive login shells)
  printf 'HAPI_API_URL=http://%s:%s\nCLI_API_TOKEN=%s\n' "$GW" "$port" "$token" \
    | incus file push - "$name/etc/hapi.env"
  incus exec "$name" -- systemctl enable --now hapi-runner
  echo "✓ $name -> http://$GW:$port"
}

launch_runner hapi-personal-runner personal-workspace 3006 "${PERSONAL_TOKEN:?set in $ENV_FILE}"
launch_runner hapi-work-runner     work-workspace     3007 "${WORK_TOKEN:?set in $ENV_FILE}"

cat <<EOF

Done. Verify:
  incus list
  incus exec hapi-personal-runner -- systemctl status hapi-runner
  incus exec hapi-personal-runner -- curl -sI http://$GW:3006

Scenario B (interactive agent shell):
  incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'
EOF
