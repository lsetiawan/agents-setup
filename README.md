# agents-setup

Scripts for running coding agents (Claude Code, GitHub Copilot, opencode)
inside isolated [incus](https://linuxcontainers.org/incus/) containers, each
with a project directory mounted in and credentials injected at startup
instead of baked into the image.

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
  (`pixi run remove-all-containers [claude]`).
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

## License

[MIT](LICENSE)
