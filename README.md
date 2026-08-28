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

## Layout

- [`scripts/claude-code/`](scripts/claude-code/README.md) — build a Claude
  Code base image and launch project containers from it. Working, see its
  README for usage.
- `scripts/copilot/` — Copilot base image build script. In progress.
- `scripts/opencode/` — opencode setup. In progress, no sandboxing yet.
- `pixi.toml` — local pixi workspace for this repo's own tooling.

## Getting started

Each agent's setup lives under `scripts/<agent>/` with its own build
script and, where applicable, a launcher at the repo root
(e.g. `start_claude_vm.sh`). Start with the Claude Code README linked
above; the same `incus launch` → provision → `publish` pattern is shared
across the other agents as they're finished.

Credentials (API keys, base URLs, etc.) go in a repo-root `.env` file —
copy `.env-example` to `.env` and fill it in. `.env` is gitignored and
is only ever pushed into a container's runtime config, never into a
published image.

## License

[MIT](LICENSE)
