# Manually Running & Testing Codex inside `hapi-personal-runner`

A focused, copy-paste walkthrough for SSHing into the **netcup** host, entering
the Incus runner, and confirming Codex works — both as the bare `codex` CLI and
through HAPI's wrapper (`hapi codex`). Complements `RUNBOOK.md` (full ops) and
`README.md` (overview).

> **Context for netcup:** `incus` needs root here — always `sudo incus …`. The
> runner is `hapi-personal-runner`; the host SSH alias is `netcup-us-admin`; the
> hub is the local Docker stack reachable from inside the runner at
> `http://10.236.0.1:3006`.

---

## 0. Prerequisites (verify, don't assume)

```sh
# From your Mac — hop onto the netcup host.
ssh netcup-us-admin

# The runner should be RUNNING with an IPv4 (Incus bridge address).
sudo incus list -c ns4
```

Expected: `hapi-personal-runner | RUNNING | 10.x.x.x (eth0)`.

If it is `STOPPED`, start it: `sudo incus start hapi-personal-runner`.
If it does not exist at all, provision it first (`RUNBOOK.md` §2 or §6.4).

---

## 1. Confirm the Codex CLI is installed in the runner

```sh
sudo incus exec hapi-personal-runner -- bash -lc 'codex --version'
```

You should get a version string. If `codex: command not found`, the golden
image was built without it — reinstall inside the container:

```sh
sudo incus exec hapi-personal-runner -- bash -lc \
  'npm install -g @openai/codex && codex --version'
```

---

## 2. Make sure Codex is authenticated

Codex uses **ChatGPT OAuth** (`auth_mode: chatgpt`). The credential lives at
`/root/.codex/auth.json` *inside* the runner. It is **not** baked into the
image — it is pushed per-runner. Check whether it is present:

```sh
sudo incus exec hapi-personal-runner -- bash -lc \
  'test -f /root/.codex/auth.json && echo "auth.json present" || echo "MISSING"'
```

### If it is MISSING (or tokens expired)

Authenticate **on the netcup host** (or your Mac), then push the file in:

```sh
# On the host where you can complete the browser OAuth flow:
codex login          # opens the ChatGPT OAuth flow; writes ~/.codex/auth.json

# Push it into the runner and restart the always-on service.
sudo incus file push ~/.codex/auth.json \
     hapi-personal-runner/root/.codex/auth.json
sudo incus exec hapi-personal-runner -- systemctl restart hapi-runner
```

> Tokens expire. When Codex starts failing auth later, re-run `codex login` on
> the host, re-push `auth.json`, restart the service.

Also confirm the workspace is trusted (cloud-init writes this; verify it
survived):

```sh
sudo incus exec hapi-personal-runner -- cat /root/.codex/config.toml
# expect:  [projects."/workspace"]  trust_level = "trusted"
```

---

## 3. Smoke test — bare `codex` CLI (no HAPI)

This proves Codex itself runs and is authenticated, independent of the hub.
Run it **non-interactively** against the trusted `/workspace`:

```sh
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc \
  'codex exec "print hello from the incus runner and exit"'
```

- `-t` allocates a TTY (Codex is happier with one).
- `--cwd /workspace` runs in the trusted project dir, so it won't block on a
  trust prompt.
- A clean response (no auth error) = Codex is working.

For a fully interactive session instead:

```sh
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'codex'
```

Type a prompt, confirm it answers, then `/exit` (or `Ctrl-C`).

---

## 4. Test through HAPI — `hapi codex` (Scenario B)

This is the real integration: the wrapper launches Codex *and* registers the
session with the hub, so it shows up in the web UI / Telegram. The
`/etc/profile.d/hapi.sh` drop-in makes interactive login shells inherit
`HAPI_API_URL` + token from `/etc/hapi.env`, so no extra env is needed.

```sh
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'
```

What to verify:

1. The session starts and Codex accepts a prompt.
2. It appears in the hub — open the web UI (or `sudo incus exec
   hapi-personal-runner -- journalctl -u hapi-runner -n 20 --no-pager` for the
   always-on runner's view) and confirm a live Codex session is listed.
3. Send a trivial prompt (e.g. "list files in this directory"), confirm the
   response streams back.

Exit the session when done.

> Sanity-check the hub link from *inside* the runner if the session doesn't
> register:
> ```sh
> sudo incus exec hapi-personal-runner -- bash -lc 'echo $HAPI_API_URL; \
>   curl -sI http://10.236.0.1:3006'
> ```
> Expect `HAPI_API_URL=http://10.236.0.1:3006` and an HTTP response.

---

## 5. (Optional) Poke around interactively

Drop into a plain login shell to inspect state, run Codex by hand, read configs:

```sh
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -l
# now inside the runner:
codex --version
cat /root/.codex/config.toml
ls -la /workspace
exit
```

---

## Troubleshooting quick table

| Symptom | Likely cause | Fix |
|---|---|---|
| `codex: command not found` | CLI not in image | `npm install -g @openai/codex` (step 1) |
| Auth / 401 errors | `auth.json` missing or token expired | `codex login` on host → `incus file push` → restart (step 2) |
| Codex blocks on a trust prompt | not run from `/workspace`, or trust config lost | use `--cwd /workspace`; verify `config.toml` (step 2) |
| Session doesn't appear in hub | env not inherited / hub unreachable | use a **login** shell (`bash -lc`); check `$HAPI_API_URL` + `curl` (step 4) |
| `Failed to connect to bus` after launch | systemd not ready yet | wait until `systemctl is-system-running` returns `running`/`degraded` |

---

### One-liners cheat sheet

```sh
# status
sudo incus list -c ns4

# version + auth presence
sudo incus exec hapi-personal-runner -- bash -lc \
  'codex --version; test -f /root/.codex/auth.json && echo auth-ok || echo NO-AUTH'

# refresh codex creds
codex login && sudo incus file push ~/.codex/auth.json \
  hapi-personal-runner/root/.codex/auth.json && \
  sudo incus exec hapi-personal-runner -- systemctl restart hapi-runner

# bare codex smoke test
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc \
  'codex exec "say hi and exit"'

# via hapi (registers with hub)
sudo incus exec hapi-personal-runner -t --cwd /workspace -- bash -lc 'hapi codex'
```
