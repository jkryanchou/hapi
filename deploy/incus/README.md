# HAPI runners on Incus (LXC)

The HAPI **runners** run as Incus system containers, one per host (the single
hub + cloudflared stay in Docker on netcup — see `../docker-compose.yml`):

- `hapi-personal-runner` on **netcup** → hub at `http://10.236.0.1:3006` (Incus bridge GW)
- `hapi-work-runner` on **ir-devnode-ryan** → hub at `https://hapi.jkryanchou.com` (via the tunnel)

System containers give agents a full OS: `apt install`, `sudo`, background
services, even Docker-in-container — the capabilities a coding agent expects,
with stronger unprivileged isolation than a Docker app container.

## Files

| File | Purpose |
|------|---------|
| `cloud-init.runner.yaml` | Provisions a stock `ubuntu/24.04/cloud` into a runner (Bun + Node 22 + agent CLIs + hapi source + systemd unit). Source of truth for the golden image. |
| `hapi-runner.service` | Canonical copy of the systemd unit (also embedded in cloud-init). |
| `profile-hapi-runner.yaml` | Reference of the `hapi-runner` Incus profile (built live by `bootstrap.sh`). |
| `bootstrap.sh` | Build the golden image once, then launch + provision ONE runner (parameterized; run once per host). |

## One-time host setup (netcup Debian 13 / devnode Ubuntu 24.04)

```sh
sudo apt update && sudo apt install -y incus btrfs-progs
sudo adduser "$USER" incus-admin            # re-login afterwards
sudo incus admin init                       # storage=btrfs; bridge=incusbr0
```

**Hosts that also run Docker (netcup only):** Docker and Incus share the kernel
firewall; Docker sets `FORWARD DROP` which blocks `incusbr0`. Fix once:

```sh
echo '{ "ip-forward-no-drop": true }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
# Fallback: sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT
```

Docker-free hosts (the devnode) skip this.

## Deploy

`bootstrap.sh` provisions ONE runner per invocation, driven by env vars.
`HAPI_TOKEN` comes from `$ENV_FILE` (default `~/deploy/.env`) or the environment.
Agent creds (`~/.codex`, `~/.local/share/opencode`, `~/.claude`, `~/.gemini`)
are pushed from the invoking host's `$HOME`; missing ones are skipped.

```sh
# netcup (hub on the same host):
RUNNER_NAME=hapi-personal-runner WORKSPACE_VOL=personal-workspace \
HAPI_API_URL=http://10.236.0.1:3006 bash deploy/incus/bootstrap.sh

# devnode (hub reached via the Cloudflare tunnel):
RUNNER_NAME=hapi-work-runner WORKSPACE_VOL=work-workspace \
HAPI_API_URL=https://hapi.jkryanchou.com HAPI_TOKEN=... \
ENV_FILE=/dev/null bash deploy/incus/bootstrap.sh
```

## Two ways to run agents

**A. Hub-driven daemon (always-on):** the `hapi-runner` systemd service runs
`runner start-sync`, registers with the hub, and powers the web UI + Telegram.

**B. Interactive shell (code-on-incus style):** drop into a container and run an
agent directly in the terminal:

```sh
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'
#   or:  hapi opencode  |  hapi gemini  |  hapi   (Claude, the default)
```

Because `/etc/hapi.env` is sourced by login shells, this interactive session
also registers with the same hub — visible/controllable from web + Telegram.
For a fresh throwaway box per task, clone the golden image with `--ephemeral`:

```sh
incus launch hapi-runner-golden box-foo --ephemeral --profile hapi-runner
incus exec box-foo -t --cwd /workspace -- bash -lc 'hapi codex'
```

## Extra tooling on the runner

Both are provisioned by `cloud-init.runner.yaml` (in the golden image) and can also
be installed live into a running runner via `incus exec` (no re-publish).

**Herdr** — an agent-aware terminal multiplexer (`herdr.dev`): run several agents in
panes with live agent-state detection, persistence, and a socket API. Additive; it
does not touch the `hapi-runner` daemon. Use it interactively:

```sh
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc herdr
# inside: herdr agent start dev --cwd /workspace -- claude   (sidebar shows state)
```

Agent integrations (`herdr integration install claude|codex|opencode`) are installed
at provisioning; **re-run them after a creds refresh** — `incus file push -r ~/.claude`
overwrites the hook Herdr drops under `~/.claude`.

**Webtop** — a browser-accessible Linux desktop (`lscr.io/linuxserver/webtop`) run as a
nested Docker container for visual web browsing. On-demand (heavy: ~1-2 GB RAM, 1 GB
shm). Start it, then reach it over a host-loopback proxy + SSH tunnel — never expose a
privileged desktop publicly:

```sh
incus exec hapi-personal-runner -- env WEBTOP_PASSWORD=<pw> hapi-webtop start
incus config device add hapi-personal-runner webtop proxy \
  listen=tcp:127.0.0.1:3001 connect=tcp:127.0.0.1:3001        # on the host
ssh -L 3001:127.0.0.1:3001 netcup-us-admin                    # from your Mac
# open https://localhost:3001  (basic-auth user: hapi)
incus exec hapi-personal-runner -- hapi-webtop stop           # stop when idle
```

## Update HAPI

```sh
incus exec hapi-personal-runner -- bash -lc 'cd /opt/hapi && git pull && /root/.bun/bin/bun install'
incus exec hapi-personal-runner -- systemctl restart hapi-runner
```
