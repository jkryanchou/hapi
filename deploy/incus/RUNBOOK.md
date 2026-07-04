# HAPI Incus Runner — Operations Runbook

Hands-on manual procedures for the Incus (LXC) runners. Complements
`README.md` (overview) and the repo-root `HANDOFF.md` (architecture). Every
command here is run **on the runner host** over SSH.

> **incus needs privileges.** On netcup use `sudo incus …` (the `admin` user is
> not yet re-logged into the `incus-admin` group). On the devnode the `ubuntu`
> user *is* in `incus-admin`, so plain `incus …` works — but `sudo incus …` is
> always safe and is used throughout this doc for consistency.

## Topology (current)

| Runner | Host | SSH alias | Hub link (`HAPI_API_URL`) |
|---|---|---|---|
| `hapi-personal-runner` | netcup (Debian 13) | `netcup-us-admin` | `http://10.236.0.1:3006` (Incus bridge GW, same host as hub) |
| `hapi-work-runner` | AWS devbox (Ubuntu 24.04) | `ir-devnode-ryan` | `https://hapi.jkryanchou.com` (via Cloudflare tunnel) |

Both share the hub's base token (`HAPI_TOKEN`), single namespace `default`.

---

## 1. One-time host setup

```sh
sudo apt update && sudo apt install -y incus btrfs-progs
sudo adduser "$USER" incus-admin      # re-login afterwards
sudo incus admin init --minimal       # dir/btrfs pool 'default' + bridge incusbr0
```

**netcup only** (it also runs Docker, which sets `FORWARD DROP` and blocks the
Incus bridge):

```sh
sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT
sudo iptables -I DOCKER-USER -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo apt install -y iptables-persistent && sudo netfilter-persistent save
```

The devnode runs no Docker → skip the firewall step.

> If `incus admin init --minimal` names the bridge `incusbr1` because an orphan
> `incusbr0` already exists, see **§6.2**.

---

## 2. Provision a runner (bootstrap)

`bootstrap.sh` is parameterized — one invocation per host. It builds a golden
image once (`hapi-runner-golden`), launches the runner, attaches `/workspace`,
pushes agent creds from the **invoking host's** `$HOME`, writes `/etc/hapi.env`,
and starts the service.

```sh
# netcup
RUNNER_NAME=hapi-personal-runner WORKSPACE_VOL=personal-workspace \
HAPI_API_URL=http://10.236.0.1:3006 bash ~/deploy/incus/bootstrap.sh

# devnode (token from an env file; agents authenticate later)
RUNNER_NAME=hapi-work-runner WORKSPACE_VOL=work-workspace \
HAPI_API_URL=https://hapi.jkryanchou.com \
ENV_FILE=$HOME/.hapi-bootstrap.env bash ~/deploy-incus/bootstrap.sh
```

`HAPI_TOKEN` is read from `$ENV_FILE` (default `~/deploy/.env`) or the
environment.

> **Run bootstrap detached on a small/flaky box.** `incus publish` (packing the
> ~1.7 GB golden image) is CPU/IO heavy and has knocked the devnode offline
> mid-run. An SSH drop kills a foreground bootstrap. Always:
> ```sh
> nohup bash ~/deploy-incus/bootstrap.sh > ~/bootstrap.log 2>&1 &
> # then poll: tail -f ~/bootstrap.log
> ```
> See **§6.4** to relaunch a runner *without* re-publishing once the golden
> image exists.

> **systemd-not-ready race.** Right after `incus launch`, the container's
> systemd bus may not be up, so `systemctl enable --now hapi-runner` can fail
> with *"Failed to connect to bus"*. Wait first:
> ```sh
> until sudo incus exec <runner> -- systemctl is-system-running 2>/dev/null \
>   | grep -qE 'running|degraded'; do sleep 5; done
> ```

---

## 3. Day-2 operations

### Update HAPI to the latest `main`

```sh
sudo incus exec <runner> -- bash -lc 'cd /opt/hapi && git fetch origin && \
  git reset --hard origin/main && /root/.bun/bin/bun install'
sudo incus exec <runner> -- systemctl restart hapi-runner
```

> `reset --hard` (not `pull --ff-only`) because `main` is periodically
> force-pushed (rebased onto new upstream releases). The clone is a deploy
> artifact with no local work to preserve.

### Health / logs

```sh
sudo incus list -c ns4                                   # state + IPv4
sudo incus exec <runner> -- systemctl is-active hapi-runner
sudo incus exec <runner> -- journalctl -u hapi-runner -n 20 --no-pager
# from netcup, prove the hub is reachable from inside the runner:
sudo incus exec hapi-personal-runner -- curl -sI http://10.236.0.1:3006
```

A healthy runner logs `Waiting for sessions.` and `Hub URL: …`.

### Interactive agent shell (Scenario B)

```sh
sudo incus exec <runner> -t --cwd /workspace -- bash -lc 'hapi codex'
#   or: hapi opencode | hapi gemini | hapi   (Claude, default)
sudo incus exec <runner> -t --cwd /workspace -- bash -l   # plain shell
```

### Provision / refresh agent credentials

Creds are files inside the runner (writable rootfs). Push from the host, then
restart:

```sh
sudo incus file push -r ~/.claude  <runner>/root/.claude
sudo incus file push -r ~/.gemini  <runner>/root/.gemini
sudo incus file push ~/.codex/auth.json <runner>/root/.codex/auth.json
sudo incus file push ~/.local/share/opencode/auth.json \
     <runner>/root/.local/share/opencode/auth.json
sudo incus exec <runner> -- systemctl restart hapi-runner
```

> Codex uses ChatGPT OAuth (`auth_mode: chatgpt`); tokens expire — re-run
> `codex login` on the host, re-push `auth.json`, restart.
> Never copy host SSH private keys in; generate a deploy key *inside* the runner.

### Herdr — multi-agent multiplexer (interactive)

Installed at provisioning (`/root/.local/bin/herdr`, symlinked to `/usr/local/bin`).
Additive — does not touch the `hapi-runner` daemon. Live-install into a running runner:

```sh
sudo incus exec <runner> -- bash -lc 'curl -fsSL https://herdr.dev/install.sh | sh'
sudo incus exec <runner> -- ln -sf /root/.local/bin/herdr /usr/local/bin/herdr
sudo incus exec <runner> -- bash -lc \
  'for a in claude codex opencode; do herdr integration install "$a"; done; herdr integration status'
# use it:
sudo incus exec <runner> -t --cwd /workspace -- bash -lc herdr
```

> `gemini` is **not** a Herdr integration target (supported: pi, omp, claude, codex,
> copilot, devin, droid, kimi, opencode, kilo, hermes, qodercli, cursor). Herdr's codex
> integration appends to `~/.codex/config.toml` but preserves the `/workspace`
> `trust_level`. **Re-run `herdr integration install …` after any creds re-push** —
> `incus file push -r ~/.claude` overwrites the hook under `~/.claude`.

### Webtop — browser desktop (nested Docker, on-demand)

A full XFCE desktop + browser for visual web browsing, run as a nested Docker container
(`security.nesting=true` is set). Heavy (~1-2 GB RAM, 1 GB shm) — start on-demand, stop
when idle. The `hapi-webtop` helper wraps the `docker run`:

```sh
# start (image is pre-pulled at provisioning):
sudo incus exec <runner> -- env WEBTOP_PASSWORD=<pw> hapi-webtop start
# reach it: host-loopback proxy device + SSH tunnel (NEVER expose publicly):
sudo incus config device add <runner> webtop proxy \
  listen=tcp:127.0.0.1:3001 connect=tcp:127.0.0.1:3001
ssh -L 3001:127.0.0.1:3001 <host>            # then open https://localhost:3001
sudo incus exec <runner> -- hapi-webtop logs # tail; or `hapi-webtop stop`
```

> **Use `--network host`, not `-p 3001:3001`.** On Docker 29.6+ (what
> `get.docker.com` installs today, e.g. the devnode) runc cannot write the
> `net.ipv4.ip_unprivileged_port_start` sysctl in a new container netns under
> nested unprivileged LXC, so *any* bridge/port-publish container fails with
> `reopen fd 8: permission denied`. Host networking binds `:3001` in the runner's
> own netns and is reached via the loopback proxy device. (Docker 29.1.3 on
> netcup tolerates bridge mode, but `--network host` works on both — the
> `hapi-webtop` helper uses it.)
>
> Basic-auth user is `hapi`, password from `WEBTOP_PASSWORD`. A `startwm.sh`
> "Aborted (core dumped)" on first boot is a transient dbus race — XFCE recovers
> (confirm `docker exec webtop ps aux | grep xfce4-session`). An HTTP **401** at
> `https://127.0.0.1:3001` means the server is up and the auth gate is working.
> The `/config` (desktop home) persists under `/workspace/.webtop`. On the small
> devnode, prefer stopping Webtop when not in use.

---

## 4. Update HAPI version end-to-end (hub + runners)

1. On your Mac: rebase fork deploy commits onto the new upstream tag, regenerate
   `bun.lock` with the **same bun as the Dockerfile** (`bun 1.3.14`):
   `bun install` → commit. Force-push `main`.
2. CI (`docker-publish.yml`) builds & pushes `ghcr.io/jkryanchou/hapi-hub:latest`.
   Wait for green.
3. Hub: `ssh netcup-us-admin 'cd ~/deploy && docker compose pull hapi && docker compose up -d hapi'`
   (always from `~/deploy` — the project name prefixes the data volume).
4. Runners: the **§3 update** on each host.
5. The web UI is a PWA — after a hub bump, unregister the service worker
   (DevTools → Application → Service Workers) or hard-reload, or it shows the
   old cached version.

---

## 5. Decommission a runner

```sh
sudo incus stop <runner> && sudo incus delete <runner>
sudo incus storage volume delete default <workspace-vol>
```

---

## 6. Recovery playbook

### 6.1 incus daemon crash-loop / corrupted database

**Symptom:** every `incus` command returns `Error: Get "http://unix.socket/1.0": EOF`;
`journalctl -u incus` shows a crash loop with
`vfsDatabaseRead: Assertion 'amount == (int)page_size' failed` and
`Main process exited, code=dumped, signal=ABRT`. Cause: unclean shutdown / hard
stop truncated the dqlite database.

**Fix (clean reset — discards incus DB state; on-disk container rootfs is kept
in the backup but the rebuild starts fresh):**

```sh
# 1. stop the crash loop (service + socket)
sudo systemctl stop incus.service incus.socket
sudo systemctl reset-failed incus.service

# 2. back up the corrupt state dir
sudo mv /var/lib/incus "/var/lib/incus.corrupt.$(date +%Y%m%d-%H%M%S)"

# 3. start fresh — incusd recreates an empty DB
sudo systemctl start incus.socket incus.service
sudo incus admin waitready --timeout=120

# 4. recreate pool + bridge
sudo incus admin init --minimal
```

Then continue to **§6.2** (bridge) and **§6.4** (relaunch the runner).

### 6.2 Bridge orphaned / unmanaged after a reset

**Symptom:** after a DB reset, `incus network list` shows `incusbr0` as
`MANAGED=NO` (a leftover kernel netdev still holding the old IP), and
`incus admin init` created `incusbr1` instead. Our `bootstrap.sh` hardcodes
`network=incusbr0`, so make `incusbr0` a proper managed NAT bridge:

```sh
sudo ip link delete incusbr0                       # remove the orphan kernel bridge
sudo incus network create incusbr0 \
     ipv4.address=10.247.136.1/24 ipv4.nat=true ipv6.address=none
sudo incus profile device set default eth0 network=incusbr0   # repoint default
sudo incus network delete incusbr1                 # drop the spurious bridge
# verify: MANAGED=YES, ipv4.nat=true
sudo incus network list | grep incusbr0
```

### 6.3 Container stuck — cannot stop/delete (missing apparmor profile)

**Symptom:**
`incus delete --force` fails with
`Failed to destroy apparmor namespace: … apparmor_parser -RWL … incus-<name> not found … exit status 2`.
The container's apparmor profile file went missing (inconsistent state), and
unload returns non-zero, blocking stop/delete.

**Fix — stub the missing profile so the unload succeeds, then delete:**

```sh
PROF=/var/lib/incus/security/apparmor/profiles/incus-<runner>
printf 'profile "incus-<runner>" flags=(unconfined) {\n}\n' | sudo tee "$PROF" >/dev/null
sudo apparmor_parser -rWL /var/lib/incus/security/apparmor/cache "$PROF" || true
sudo incus stop  <runner> --force || true
sudo incus delete <runner> --force
```

### 6.4 Relaunch a runner from the existing golden image (no re-publish)

When the golden image already exists (`incus image alias list | grep golden`),
**skip `bootstrap.sh`** — relaunching directly avoids the heavy `incus publish`
that can OOM a small box. This is the tail of bootstrap, done by hand:

```sh
source ~/.hapi-bootstrap.env          # provides HAPI_TOKEN (do not echo it)
API_URL=https://hapi.jkryanchou.com   # or http://10.236.0.1:3006 on netcup

sudo incus launch hapi-runner-golden <runner> --profile hapi-runner
sudo incus config device add <runner> workspace disk \
     pool=default source=<workspace-vol> path=/workspace

# wait for systemd, then provision the hub link + token
until sudo incus exec <runner> -- systemctl is-system-running 2>/dev/null \
  | grep -qE 'running|degraded'; do sleep 5; done
printf 'HAPI_API_URL=%s\nCLI_API_TOKEN=%s\n' "$API_URL" "$HAPI_TOKEN" \
  | sudo incus file push - <runner>/etc/hapi.env
sudo incus exec <runner> -- systemctl enable --now hapi-runner

# verify
sudo incus exec <runner> -- journalctl -u hapi-runner -n 15 --no-pager
```

> Run this **detached** (`nohup … &`) if the box is flaky. Never trace the token
> — do **not** use `set -x` in a script that reads `HAPI_TOKEN`; it leaks the
> secret to the log.

### 6.5 Box unresponsive during `incus publish`

`incus publish` (golden-image build) is the heaviest operation and has hung the
small devnode (SSH banner timeout, no recovery). If it happens:

1. Reboot the instance (AWS console — SSH won't reach a hung box).
2. After it's back, check whether the golden image actually published
   (`incus image alias list | grep golden`) and whether the runner launched
   (`incus list`). If the image exists, finish via **§6.4** (no re-publish).
3. To avoid it entirely on a small box, build the golden image once during a
   quiet window, or launch runners directly from the Ubuntu cloud image with the
   `hapi-runner` profile (cloud-init provisions on first boot).

---

## 7. Proxy egress + skills

### 7.1 SOCKS5→HTTP bridge (gost)

All agents (claude/codex/gemini/opencode) route egress through a local HTTP
proxy at `127.0.0.1:8118`, which forwards to an authenticated SOCKS5 upstream.
The `socks2http.service` systemd unit runs `gost` and reads credentials from
`/etc/socks2http.env` (0600, pushed per-runner — never in git).

**Provision the SOCKS5 creds** (replace values with the actual upstream):
```sh
printf 'SOCKS_USER=%s\nSOCKS_PASS=%s\nSOCKS_HOST=%s\nSOCKS_PORT=%s\n' \
  <user> <pass> <host> <port> \
  | sudo incus file push - <runner>/etc/socks2http.env --mode=0600
sudo incus exec <runner> -- chown root:root /etc/socks2http.env
sudo incus exec <runner> -- systemctl start socks2http
```

**Proxy env** is injected via `/etc/hapi.env` (append once after
provisioning the creds). The daemon and all spawned agents inherit it:
```
HTTP_PROXY=http://127.0.0.1:8118
HTTPS_PROXY=http://127.0.0.1:8118
ALL_PROXY=http://127.0.0.1:8118
http_proxy=http://127.0.0.1:8118
https_proxy=http://127.0.0.1:8118
all_proxy=http://127.0.0.1:8118
NO_PROXY=localhost,127.0.0.1,::1,10.236.0.1,.incusbr0
no_proxy=localhost,127.0.0.1,::1,10.236.0.1,.incusbr0
```
(`NO_PROXY` must include `10.236.0.1` — the Incus bridge hub address — and loopback; each agent's own local callback servers must NOT go through the proxy.)

**Verify the bridge:**
```sh
sudo incus exec <runner> -- bash -lc \
  'curl -s -x http://127.0.0.1:8118 https://api.ipify.org; echo (proxied); \
   curl -s https://api.ipify.org; echo (direct)'
# Proxied IP must differ from direct IP.
sudo incus exec <runner> -- ss -ltnp | grep 8118  # gost bound
```

> **Codex ChatGPT-OAuth risk:** the proxy changes the egress IP, which can
> trigger OAuth refresh failures. Verify Codex auth right after enabling;
> if it 401s, add the OpenAI auth host to `NO_PROXY` or switch to API-key auth.
>
> **Large binary downloads** (agent-browser Chrome, gstack browser): set
> `unset HTTP_PROXY HTTPS_PROXY ...` for those specific downloads — the
> residential proxy throttles large transfers.

### 7.2 Skills for all four agents

Skills are installed globally into the runner (`/root/...`) at provisioning:

| Skill | Claude | Codex | Gemini | opencode |
|---|---|---|---|---|
| superpowers | plugin v6.0.3 | **manual `/plugins` TUI** | extension | plugin entry in opencode.json |
| gsd (69 skills) | `~/.claude/skills/` | `~/.codex/skills/` | `~/.gemini/gsd-core/` | `~/.config/opencode/skills/` |
| gstack | `~/.claude/skills/gstack/` | `~/.codex/skills/gstack/` | N/A | `~/.config/opencode/skills/gstack/` |
| firecrawl (31 skills, key deferred) | `~/.claude/skills/` | `~/.agents/skills/` | `~/.agents/skills/` | `~/.agents/skills/` |
| agent-browser (+CLI+Chrome) | `~/.agents/skills/` (symlinked) | `~/.agents/skills/` | `~/.agents/skills/` | `~/.agents/skills/` |
| grill-me / grill-with-docs | `~/.agents/skills/` | `~/.agents/skills/` | `~/.agents/skills/` | `~/.agents/skills/` |

**firecrawl activation:** add `FIRECRAWL_API_KEY=fc-<key>` to `/etc/hapi.env`
(and restart `hapi-runner`). Also configure the MCP server per agent for the
full tool-call interface:
- Claude: `claude mcp add firecrawl -- npx -y firecrawl-mcp`
- Codex: add `[mcp_servers.firecrawl]` to `~/.codex/config.toml`
- Gemini: add `mcpServers.firecrawl` to `~/.gemini/settings.json`
- opencode: add to `~/.config/opencode/opencode.json` `mcp` block

**superpowers for Codex:** not headless-installable. Install interactively:
```sh
sudo incus exec <runner> -t --cwd /workspace -- bash -lc 'codex'
# Inside Codex TUI: type /plugins → search superpowers → Install Plugin
```

**Creds-repush caveat:** `incus file push -r ~/.claude` overwrites
`/root/.claude`, removing skills + Herdr hooks. `incus file push -r ~/.gemini`
overwrites `/root/.gemini`, removing the superpowers extension. After any
creds refresh, re-run the affected skill installs:
```sh
# Re-install Claude skills (superpowers + firecrawl + agent-browser + grill-*)
sudo incus exec <runner> -- bash -lc 'claude plugin marketplace add obra/superpowers-marketplace; claude plugin install superpowers@superpowers-marketplace'
sudo incus exec <runner> -- bash -lc 'npx -y firecrawl-cli@latest init --all -y --skip-auth; npx -y skills@latest add vercel-labs/agent-browser mattpocock/skills -a claude-code -g -y'
# Re-install Gemini superpowers extension
sudo incus exec <runner> -- bash -lc 'echo y | gemini extensions install https://github.com/obra/superpowers --consent'
# Re-run Herdr integrations (also clobbered by ~/.claude push)
sudo incus exec <runner> -- bash -lc 'for a in claude codex opencode; do herdr integration install "$a"; done'
```

**Quick health check:**
```sh
sudo incus exec <runner> -- bash -lc '
  systemctl is-active socks2http hapi-runner
  curl -s -x http://127.0.0.1:8118 https://api.ipify.org; echo
  claude plugin list 2>&1 | grep superpowers
  ls /root/.agents/skills/ | wc -l; echo agent-skills
  ls /root/.codex/skills/ | grep ^gsd | wc -l; echo gsd-codex
'
```

---

## 8. Gotchas (quick reference)

- `incus` needs `sudo` on netcup (group re-login pending); plain on devnode.
- `bun.lock` must be regenerated with **bun 1.3.14** (matches `oven/bun` in the
  Dockerfile) or the CI `--frozen-lockfile` build fails.
- Run `docker compose` from `~/deploy` only — project name prefixes the hub
  data volume; elsewhere silently creates an empty one.
- Runner updates use `git reset --hard origin/main` (main gets force-pushed).
- Never `set -x` around `HAPI_TOKEN`; never push host SSH private keys into a
  runner.
- The hub web UI is an aggressively-cached PWA — unregister the service worker
  after a version bump to see the new version.
- Backups created by recovery (`/var/lib/incus.corrupt.*`) are large; delete
  once the rebuild is verified.
