# Legacy

`Dockerfile.runner` is retired. The HAPI **runner** now runs as an Incus (LXC)
system container, not a Docker image — see `deploy/incus/` and `HANDOFF.md`.

Kept here for reference (the agent CLI install steps and the auth-seeding CMD
were the basis for `deploy/incus/cloud-init.runner.yaml`). Not built by CI.
