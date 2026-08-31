# agents-setup

Scripts for running coding agents (Claude Code, GitHub Copilot, opencode)
inside isolated [incus](https://linuxcontainers.org/incus/) containers, each
with a project directory mounted in and credentials injected at startup
instead of baked into the image. Model traffic goes through a local
LiteLLM proxy, so the upstream gateway credentials stay on the host and
all container spend is logged in one place.

## Requirements

- [pixi](https://pixi.sh) — manages this repo's own tooling and tasks.
- [Homebrew](https://brew.sh) — used to install Colima.
- [Colima](https://colima.run/#quick-start) — provides the `incus` VM
  backend the scripts under `scripts/` launch containers in. Required
  on `PATH`; `pixi run`/`pixi shell` will fail fast with instructions
  if it's missing (see `scripts/check_colima.sh`).

Note: This is currently tested on MacOS ONLY

## Layout

- [`scripts/claude-code/`](scripts/claude-code/README.md) — build a Claude
  Code base image and launch project containers from it. Working, see its
  README for usage.
- `scripts/copilot/` — Copilot base image build script. In progress.
- `scripts/opencode/` — opencode setup. In progress, no sandboxing yet.
- `scripts/setup_claude_link.sh` — symlink `claude` inside the pixi
  environment to the launcher (`pixi run setup-claude`).
- `scripts/remove_running_containers.sh` — delete running incus
  containers after confirmation, optionally filtered to one harness
  (`pixi run remove-all-containers [claude]`). Persisted `~/.claude`
  state is left on the host.
- [`scripts/litellm/`](scripts/litellm/README.md) — a local LiteLLM proxy
  in front of the upstream gateway and your oMLX models, with spend logs
  in a local Postgres (`pixi run litellm` / `pixi run stop-litellm`).
  Runs on the host under pixi rather than in a container.
- `pixi.toml` — local pixi workspace for this repo's own tooling.

## Getting started

Each agent's setup lives under `scripts/<agent>/` with its own build
script and, where applicable, a launcher under `scripts/`
(e.g. `start_claude_vm.sh`, wired up as `pixi run claude`). Start with
the Claude Code README linked above; the same `incus launch` →
provision → `publish` pattern is shared across the other agents as
they're finished.

The tasks don't have to be run from inside this repo — point pixi at
the manifest and launch an agent from whatever project you're in:

```bash
pixi run --manifest-path /path/to/agents-setup/pixi.toml claude
```

The launcher mounts the directory you ran that from, not the repo.

If you'd rather just type `claude`, run `pixi run setup-claude` once. It
symlinks `claude` into the environment's `bin/`, so inside `pixi shell`
the launcher shadows any host-installed Claude Code and mounts your
current directory. Re-run it if pixi rebuilds the environment.

Credentials (API keys, base URLs, etc.) go in a `.env` file — copy
`.env-example` to `.env` and fill it in. The launcher reads `.env` from
the directory you run it in, falling back to a repo-root `.env` when
that directory has none, so you can keep one shared file or give a
project its own. `.env` is gitignored and is only ever pushed into a
container's runtime config, never into a published image.

Its `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` describe the
**upstream gateway**, which the local proxy forwards to. They are not
passed to containers — those authenticate to the proxy with
`LITELLM_MASTER_KEY` instead, so start the proxy before launching an
agent.

## Persistent agent state

Containers are disposable, but each project's `~/.claude` is not: the
launcher mounts `~/.agents-setup/claude/<project>-<hash>` into the
container at `/root/.claude` and points `CLAUDE_CONFIG_DIR` at it, so
memory, sessions, project state and `.claude.json` all outlive the
container. Delete a container, relaunch the same directory, and the
history is still there. Set `AGENTS_STATE_DIR` to keep that state
somewhere other than `~/.agents-setup`. See the Claude Code
[README](scripts/claude-code/README.md) for how it's seeded and removed.

## LiteLLM proxy

`pixi run litellm` starts a local LiteLLM proxy on
`http://127.0.0.1:4000`. It forwards Anthropic traffic to the upstream
gateway named in `.env`, serves your oMLX models alongside it, and
records spend in a Postgres cluster it creates under `.litellm/`.

The agent containers depend on it: they are pointed at the proxy rather
than the gateway, so it has to be running before `pixi run claude`.
Because a container cannot reach the host on loopback, the launcher
works out the host's address on Colima's vmnet bridge and hands the
container that. See its [README](scripts/litellm/README.md) for the
details.

## License

[MIT](LICENSE)
