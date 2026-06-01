# HAPI Self-Hosting Handoff

This document records the work done to fork, dockerize, and deploy **two HAPI
stacks** (personal + work) on the `netcup-us-admin` server behind a shared
Cloudflare Tunnel.

Last updated: 2026-06-01

---

## 1. Goal

Run two independent HAPI stacks from the fork `github.com/jkryanchou/hapi`:

| Stack    | Hub URL                              | Agents available                       |
|----------|--------------------------------------|----------------------------------------|
| personal | `https://hapi-personal.jkryanchou.com` | Claude Code, Codex, OpenCode, Gemini   |
| work     | `https://hapi-work.jkryanchou.com`     | Claude Code, Codex, OpenCode, Gemini   |

Each stack = **one hub + one dedicated runner**. A single `cloudflared`
container fronts both. The **hubs + cloudflared run in Docker** (images built by
GitHub Actions → GHCR); the **runners run as Incus (LXC) system containers**
(see §6a) so agents get a full OS to work in.

---

## 2. Architecture

```
                    Cloudflare Edge (TLS)
                            │
                  ┌─────────┴─────────┐
                  │   cloudflared      │  (--protocol http2, token-based)
                  │   (1 shared)       │
                  └─────────┬─────────┘
            ┌───────────────┴───────────────┐
            ▼                                ▼
   hapi-personal:3006              hapi-work:3006        (Docker hub: REST+SSE+Telegram)
            ▲                                ▲             published on 10.236.0.1:3006/:3007
            │ Socket.IO /cli                 │ Socket.IO /cli  (Incus → host gateway)
   hapi-personal-runner            hapi-work-runner       (Incus LXC; spawns agent sessions)
   workspace: /workspace           workspace: /workspace
```

> Hubs + cloudflared are Docker (`hapi-net`); runners are Incus (`incusbr0`).
> Runners reach their hub via the Incus bridge gateway `10.236.0.1` (hubs publish
> there). Docker's `FORWARD DROP` is neutralised with `ip-forward-no-drop` in
> `/etc/docker/daemon.json`.

- **Hub ↔ Runner pairing**: shared `CLI_API_TOKEN` per stack
  (`PERSONAL_TOKEN`, `WORK_TOKEN`).
- **Runner ↔ Hub link**: `HAPI_API_URL` points the runner at its hub over the
  internal `hapi-net` Docker network.
- **No host ports published** — all traffic flows through cloudflared.
- `--protocol http2` is **required** (QUIC/UDP is blocked on netcup; SSE needs it).

---

## 3. Images (GHCR)

Built by `.github/workflows/docker-publish.yml` on push to `main`, on `v*` tags,
and via `workflow_dispatch`. Matrix builds both images; pushes `:latest` + `:sha`.

| Image                              | Dockerfile         | Contents                                          |
|------------------------------------|--------------------|---------------------------------------------------|
| `ghcr.io/jkryanchou/hapi-hub`      | `Dockerfile`       | Hub + embedded web PWA (slim runtime)             |

Auth uses the workflow's `GITHUB_TOKEN` with `packages: write` — no PAT needed.

> The runner is **no longer a Docker image**. It is an Incus container built from
> `deploy/incus/cloud-init.runner.yaml` + a local golden snapshot (no registry).
> `Dockerfile.runner` is retired to `deploy/legacy/`.

---

## 4. Key Files

| File                          | Purpose                                                       |
|-------------------------------|---------------------------------------------------------------|
| `Dockerfile`                  | hub image; embeds PWA via `generate:embedded-web-assets`      |
| `.dockerignore`               | excludes git, node_modules, dist, generated assets            |
| `.github/workflows/docker-publish.yml` | CI build/push the **hub** image to GHCR              |
| `deploy/docker-compose.yml`   | 3 services (2 hubs + cloudflared); runners are Incus now      |
| `deploy/.env.example`         | documents required env vars                                   |
| `deploy/incus/`               | runner cloud-init, systemd unit, profile, `bootstrap.sh`      |
| `deploy/legacy/Dockerfile.runner` | retired Docker runner image (basis for the cloud-init)    |

---

## 5. Runner startup (Incus systemd unit)

The runner is an Incus system container running `hapi-runner.service` (see
`deploy/incus/hapi-runner.service`). systemd owns restart/signals — no more
`exec bun` PID-1 trick or hand-rolled CMD shell. The unit:

1. `ConditionPathExists=/etc/hapi.env` — stays inactive until the hub link/token
   is provisioned (`bootstrap.sh` pushes it, then `systemctl enable --now`).
2. `ExecStartPre=rm -f /root/.hapi/runner.state.json*` — clears stale runner
   state (a reused PID can make `start-sync` think a runner is alive and exit).
3. `ExecStart=/root/.bun/bin/bun /opt/hapi/cli/src/index.ts runner start-sync
   --workspace-root /workspace` — foreground; `Restart=always`.

Non-secret config (codex `config.toml` trusting `/workspace`, opencode
`opencode.json` default model `github-copilot/claude-sonnet-4.6`) is baked into
the golden image by cloud-init. Update HAPI with
`git -C /opt/hapi pull && bun install && systemctl restart hapi-runner`.

---

## 6. Agent authentication strategy (Incus)

System containers have **writable** config dirs, so credentials are just files
pushed into the container once per runner (re-push only on rotation). No env-var
injection, no read-only mounts.

| Agent       | Method (`incus file push` into the runner)  |
|-------------|---------------------------------------------|
| Claude Code | `~/.claude` → `/root/.claude`               |
| Gemini      | `~/.gemini` → `/root/.gemini`               |
| OpenCode    | `~/.local/share/opencode/auth.json`         |
| Codex       | `~/.codex/auth.json`                         |

### Codex specifics
- Codex Pro uses **ChatGPT OAuth tokens** (`auth_mode: chatgpt`), NOT
  `OPENAI_API_KEY`. The `auth.json` contains `id_token`, `access_token`,
  `refresh_token`, and `account_id`.
- To refresh on netcup: `codex login` locally, then
  `incus file push ~/.codex/auth.json hapi-personal-runner/root/.codex/auth.json`
  and `incus exec hapi-personal-runner -- systemctl restart hapi-runner`.

### Historical note (Docker era)
Under Docker, opencode and codex failed with `EROFS` when their config dirs were
bind-mounted `:ro` (they write at runtime), which forced the
`OPENCODE_AUTH_JSON` / `CODEX_AUTH_JSON` env-var injection hack. The Incus move
**retires that hack** — a writable rootfs makes it unnecessary.

## 6a. Why the runner moved to Incus (LXC)
Docker is an *application*-container runtime (one process); agents want to behave
like they own a machine (`apt install`, `sudo`, daemons, Docker-in-container).
Incus *system* containers provide a full OS with systemd and a writable
filesystem, plus stronger unprivileged isolation via user namespaces — the
runtime an agent actually wants. The benefit is specific to the runner, so the
hubs + cloudflared stayed in Docker (hybrid). Established pattern: `code-on-incus`,
`lincubate`, `vibebin`.

### Two ways to run agents in a runner
- **A — hub-driven daemon:** the `hapi-runner` service (above) → web UI + Telegram.
- **B — interactive shell (code-on-incus style):**
  `incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'`
  (or `hapi opencode` / `hapi gemini` / `hapi`). `/etc/profile.d/hapi.sh` sources
  `/etc/hapi.env`, so the terminal session also registers with the same hub.

---

## 7. Deployment on netcup (`netcup-us-admin`, 152.53.209.61)

- Deploy dir: **`~/deploy/`** (NOT `~/hapi/deploy`).
- Env file: `~/deploy/.env` (git-ignored; holds all secrets).
- Compose file is **copied via `scp`**, not `git pull` — netcup has no repo
  clone, and `curl` from GitHub raw can serve a stale cached version.

### Required `.env` keys (Docker hubs + Incus bootstrap)
```
TUNNEL_TOKEN=eyJ...
PERSONAL_TOKEN=...
WORK_TOKEN=...
INCUS_GW=10.236.0.1                 # incusbr0 gateway; hubs publish here
PERSONAL_TELEGRAM_BOT_TOKEN=...     # @HAPIPeronsalBot
WORK_TELEGRAM_BOT_TOKEN=...         # @HAPIWorkBot
```
> Agent creds are no longer in `.env` — `deploy/incus/bootstrap.sh` pushes
> `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, `~/.claude`,
> `~/.gemini` directly into the runners from the host home dir.

### One-time Incus host setup (Debian 13 / trixie)
```sh
sudo apt install -y incus btrfs-progs
sudo adduser admin incus-admin            # re-login (until then use `sudo incus`)
sudo incus admin init                     # btrfs pool; bridge incusbr0 = 10.236.0.1/24
```

#### Docker ↔ Incus firewall (the part that actually bit us)
`ip-forward-no-drop` in `daemon.json` was **NOT sufficient** on this host: Docker
(nft backend) still installs a `filter forward … policy drop` hook that overrides
Incus's own `fwd.incusbr0` chain, so containers got "Network is unreachable"
during cloud-init. The working fix is explicit `DOCKER-USER` ACCEPT rules for
`incusbr0`, **persisted** so they survive a Docker restart:

```sh
# Allow incusbr0 traffic through Docker's FORWARD chain
sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT
sudo iptables -I DOCKER-USER -o incusbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Persist across reboots
sudo apt install -y iptables-persistent && sudo netfilter-persistent save

# Re-apply on every Docker restart (Docker flushes DOCKER-USER on restart):
#   /usr/local/sbin/incus-docker-forward.sh   — idempotent `iptables -C || -I` of the two rules above
#   /etc/systemd/system/docker.service.d/incus-forward.conf:
#     [Service]
#     ExecStartPost=/usr/local/sbin/incus-docker-forward.sh
```
> These two host files (`incus-docker-forward.sh` + the docker.service drop-in)
> live on netcup only, not in the repo.

### Deploy / redeploy
```sh
# Docker hubs + cloudflared
scp deploy/docker-compose.yml netcup-us-admin:~/deploy/docker-compose.yml
ssh netcup-us-admin 'cd ~/deploy && docker compose pull && docker compose up -d --remove-orphans'

# Incus runners (build golden image once, then clone + provision both)
scp -r deploy/incus netcup-us-admin:~/deploy/incus
ssh netcup-us-admin 'bash ~/deploy/incus/bootstrap.sh'
```

### Update HAPI inside a runner (no image rebuild)
```sh
incus exec hapi-personal-runner -- bash -lc 'cd /opt/hapi && git pull && /root/.bun/bin/bun install'
incus exec hapi-personal-runner -- systemctl restart hapi-runner
```

---

## 7a. Using the runners — the two scenarios

A runner container serves agents in **two independent ways**. Both register with
the same hub (so anything you start is visible in the web UI + Telegram), because
the systemd unit and login shells read the same `/etc/hapi.env`.

> All `incus` commands run on the host (`ssh netcup-us-admin`). If the `admin`
> user isn't in the `incus-admin` group yet, prefix every command with `sudo`.
> Containers: `hapi-personal-runner` (hub :3006) and `hapi-work-runner` (:3007).

### Scenario A — Hub-driven daemon (web UI + Telegram)
This is the always-on path. The `hapi-runner` service runs `runner start-sync`,
connects to the hub, and spawns sessions on demand. **You don't run anything by
hand** — you drive it from the browser or Telegram:

1. Open `https://hapi-personal.jkryanchou.com` (or `…-work`).
2. **New session** → pick an agent (Claude / Codex / OpenCode / Gemini) → browse
   to a workspace dir (e.g. `/workspace/code-handoff`) → create.
3. The runner spawns the agent and streams it back over SSE; reply from the web
   UI or from the paired Telegram bot.

Operate the daemon from the host:
```sh
# Health / logs
incus exec hapi-personal-runner -- systemctl status hapi-runner
incus exec hapi-personal-runner -- journalctl -u hapi-runner -f
# Confirm the hub is reachable from inside the runner (proves the firewall fix)
incus exec hapi-personal-runner -- curl -sI http://10.236.0.1:3006
# Restart after a config/cred change
incus exec hapi-personal-runner -- systemctl restart hapi-runner
```

Add a repo to a workspace so it shows up in the **New session** browser:
```sh
# Deploy key already exists for code-handoff; clone more repos the same way.
incus exec hapi-personal-runner -- git clone git@github.com:OWNER/REPO.git /workspace/REPO
```

### Scenario B — Interactive agent shell (code-on-incus style)
Drop straight into the container and run an agent in your terminal — the
equivalent of `coi shell --tool codex`. The login shell (`bash -lc`) sources
`/etc/profile.d/hapi.sh` → `/etc/hapi.env`, so it gets `HAPI_API_URL` +
`CLI_API_TOKEN` and the session **also appears in the web UI**.

```sh
ssh netcup-us-admin

# Codex in /workspace (-t = pty for the TUI, -l = login shell for the env)
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'

# Other agents — same pattern:
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi opencode'
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi gemini'
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi'          # Claude (default)

# Just want a plain shell to poke around / apt install / git?
incus exec hapi-personal-runner -t --cwd /workspace -- bash -l
```

Variants:
```sh
# Pure local TUI, do NOT register with the hub:
incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex --hapi-starting-mode local'

# Throwaway, isolated box per task (auto-deleted on stop) — true code-on-incus flow:
incus launch hapi-runner-golden box-spike --ephemeral --profile hapi-runner
incus exec box-spike -t --cwd /workspace -- bash -lc 'hapi codex'
incus stop box-spike     # gone
```

**When to use which:** Scenario A for normal remote work (phone/web, long-running,
Telegram replies). Scenario B when you're SSH'd into the box and want a fast,
hands-on agent session or to debug the environment directly.

---

## 8. Cloudflare Tunnel

- Tunnel `hapi`, UUID `873b1a26-fce2-4f09-9f36-4a0a72272cb2`,
  account `d4aed0ddf005e866f5c80d21df7e8b09`, zone `jkryanchou.com`.
- Remotely-managed (token-based); ingress routes configured in the dashboard:
  - `hapi-personal.jkryanchou.com` → `http://hapi-personal:3006`
  - `hapi-work.jkryanchou.com` → `http://hapi-work:3006`
- Two proxied CNAMEs point at `873b1a26-….cfargotunnel.com`.
- Old `hapi.jkryanchou.com` route + DNS record removed at cutover.

---

## 9. Telegram bots

One bot per hub (a single bot cannot serve two hubs):
- Personal: `@HAPIPeronsalBot` → `PERSONAL_TELEGRAM_BOT_TOKEN`
- Work: `@HAPIWorkBot` → `WORK_TELEGRAM_BOT_TOKEN`

Wired via `TELEGRAM_BOT_TOKEN` env on each hub service.

---

## 10. Personal hub state migration

Migrated from the old Lightsail SG box (`lightsail-sg-ubuntu`, 47.130.105.246):
copied `~/.hapi/{settings.json, jwt-secret.json, owner-id.json, hapi.db*}` into
the `hapi-personal-data` volume so existing sessions, pairings, and the owner
identity carried over. `HAPI_PUBLIC_URL` env overrides the old public URL. The
SG tmux sessions were stopped (old setup retired). The personal workspace volume
was seeded with a clone of `git@github.com:jkryanchou/code-handoff.git`.

---

## 11. Problems solved (chronological)

1. **npm missing in `oven/bun`** → install Node.js 22 via NodeSource before
   `npm install -g` of agent CLIs.
2. **Runner crash-loop** (stale `runner.state.json` PID match) → `rm -f` state
   on startup; `exec bun` for correct PID 1 / signal handling.
3. **No machine in `/sessions/new`** → caused by #2; resolved once runner stayed up.
4. **OpenCode `ACP process exited (code=1)`** → `:ro` mount of opencode dirs
   caused `EROFS`. Fix: inject auth via env var, write to writable paths.
5. **OpenCode no response (HTTP 400)** → model `claude-opus-4.6` not available
   for the `opencode` integrator. Fix: default to `claude-sonnet-4.6`.
6. **One Telegram bot for two hubs** → created two bots, one per hub.
7. **Codex `Read-only file system` for `~/.codex/auth.json`** (same class as #4)
   → removed `:ro` codex bind-mount; inject `CODEX_AUTH_JSON` env var.
8. **Stale compose after `docker compose up`** → Docker reused old container with
   old mounts; fixed with `--force-recreate`. Also `curl` from GitHub raw served
   a cached file → switched to `scp` of the local compose file.
9. **Agents wanted full-OS capabilities (`apt`, `sudo`, daemons)** that Docker
   app containers fight → **migrated runners to Incus (LXC) system containers**
   (hybrid: hubs/cloudflared stay Docker). This also retired the EROFS env-var
   auth hack (#4/#7). Cross-engine fix: hubs publish on the bridge gateway
   `10.236.0.1:3006/:3007` for the runners to reach over `HAPI_API_URL`.

### Problems hit while executing the migration on netcup (2026-06-01)
10. **cloud-init "Network is unreachable"** → Docker's nft `forward … policy
    drop` overrode Incus's bridge chain; `ip-forward-no-drop` alone was not
    enough. Fix: explicit `DOCKER-USER` ACCEPT rules for `incusbr0`, persisted
    via `iptables-persistent` + a docker.service `ExecStartPost` hook (see §7).
    The golden image had to be built by hand on the first attempt because
    cloud-init failed before the firewall was fixed.
11. **`unzip` missing** → the Bun installer needs it; added to the cloud-init
    `packages` list.
12. **`cloud-init status --wait` returned too early** → resolved "done" before
    the `runcmd` npm installs finished; polled with
    `until cloud-init status | grep -qE 'done|error'` instead.
13. **`incus launch --device workspace,…` rejected** ("Device not found in
    profile devices") → `--device` at launch can only *override* existing
    profile devices. Fix: launch first, then `incus config device add <name>
    workspace disk pool=default source=<vol> path=/workspace`.
14. **`incus file push ~/.codex/auth.json` "Permission denied"** → the host
    `~/.codex` (and `~/.claude`, `~/.gemini`) were root-owned from the Docker
    bind-mount era. Fix: `sudo chown -R admin:admin ~/.codex ~/.claude ~/.gemini`.
15. **No `~/.codex/auth.json` on the host** → old Docker setup stored Codex auth
    as the `CODEX_AUTH_JSON` env var in `~/deploy/.env`, not a file. Fix:
    `grep '^CODEX_AUTH_JSON=' ~/deploy/.env | cut -d= -f2- > ~/.codex/auth.json`.
    (Note: the token nests under `tokens.access_token`, not a top-level field —
    a verification check that read `d['access_token']` wrongly reported it
    missing; the `chatgpt` OAuth auth is valid, expires ~2026-06-07.)
16. **`code-handoff` repo not visible in the session browser** → personal
    runner's `/workspace` was empty. The opencode `gho_…` token is Copilot-only
    (403 on repo clone). Fix: generated an **ed25519 deploy key inside the
    runner** (no private key moved from the host — pushing one was blocked),
    added it to `jkryanchou/code-handoff` via `gh api repos/.../keys` (read-only,
    key id 153155838), then `git clone git@github.com:jkryanchou/code-handoff.git
    /workspace/code-handoff`.

---

## 12. Current status

- ✅ CI builds and pushes the **hub** image to GHCR on every push to `main`.
- ✅ Hubs + cloudflared deployed on netcup as Docker (one Cloudflare Tunnel).
- ✅ Personal hub state migrated; SG box retired.
- ✅ Two Telegram bots configured.
- ✅ OpenCode working (GitHub Copilot, `claude-sonnet-4.6`).
- ✅ Codex working (ChatGPT OAuth); auth.json provisioned in the runner.
- ✅ **Runner → Incus migration EXECUTED on netcup (2026-06-01).** Incus 6.0.4
  installed; btrfs pool + `incusbr0` (`10.236.0.1/24`); Docker↔Incus firewall
  fixed and persisted (§7). Golden image `hapi-runner-golden` (1272.52MiB) built
  and published; cloned into `hapi-personal-runner` + `hapi-work-runner`.
  `hapi-runner.service` **active on both**; both register their `/workspace`
  with their hub ("Waiting for sessions").
- ✅ `code-handoff` cloned into the **personal** runner's `/workspace` via an
  in-container deploy key (see problem #16).
- ✅ Scenario B verified: a login shell has `HAPI_API_URL` + `CLI_API_TOKEN`;
  `apt-get install` and Docker-in-container work natively.

### Next steps / notes
- **Verify from the UI:** `hapi-personal.jkryanchou.com/sessions/new` should now
  list `code-handoff`; create a Codex session in `/workspace/code-handoff`.
- **Work runner `/workspace` is still empty** — seed it the same way if needed
  (its own deploy key, or reuse the existing one).
- **Claude + Gemini have no creds yet:** host `~/.claude` / `~/.gemini` were
  empty root-owned dirs (chowned to admin, still empty). Populate them on the
  host and `incus file push -r` into both runners before those agents will auth.
- ChatGPT OAuth tokens expire (~2026-06-07) — refresh by `codex login` locally +
  `incus file push ~/.codex/auth.json …` + `systemctl restart hapi-runner`.
- The `docs/deployment-handoff` branch (PR #3 → `jkryanchou/hapi`) holds all repo
  changes; commit this doc update and decide whether to merge.
