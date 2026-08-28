# Claude Code incus scripts

Builds a minimal Alpine incus image with Claude Code preinstalled, and
launches per-project containers from it with your project directory
mounted in and API credentials injected at startup.

## Prerequisites

- [incus](https://linuxcontainers.org/incus/) installed and initialized
  (`incus admin init`)
- A `.env` file with your credentials (copy `.env-example` and fill it
  in). The launcher reads it from the directory you invoke it in, and
  falls back to the repo root if that directory has none:

  ```
  ANTHROPIC_BASE_URL=...
  ANTHROPIC_AUTH_TOKEN=...
  ```

## Build the base image

```bash
./scripts/claude-code/build_claude_base_image.sh
```

This launches a throwaway Alpine 3.24 container, provisions it via
`setup_claude_base_image.sh` (installs `curl`, `git`, `bash`, and Claude
Code itself), applies `claude-settings.json` as the default
`~/.claude/settings.json`, then publishes it to your local incus image
registry as `claude-base-image` and deletes the builder container.

Re-run this script any time `setup_claude_base_image.sh` or
`claude-settings.json` changes — it publishes with `--reuse`, so it
overwrites the existing `claude-base-image` alias in place.

## Launch a project container

From your project directory:

```bash
pixi run claude [project_directory]
```

or directly:

```bash
./scripts/start_claude_vm.sh [project_directory]
```

- `project_directory` — host directory to mount into the container at
  `/workspace`. Defaults to the directory you ran the command in.

`pixi run` executes tasks from the workspace root, so the launcher uses
pixi's `INIT_CWD` to recover the directory you actually invoked it in —
that's the directory both the mounted workspace and the `.env` lookup
default to.

The container name is derived from the directory: `/path/to/work-dir`
becomes the container `claude--work-dir-a1b2`, where the suffix is the
first four hex characters of the path's SHA-256. The directory name is
lowercased, anything that isn't a letter, digit or hyphen becomes `-`,
and the whole name stays inside incus' 63-character limit.

Passing the same directory again therefore reuses the same container,
while two directories sharing a basename (`/a/work-dir` and
`/b/work-dir`) get separate containers. As a safety net, if a container
with the derived name exists but is mounted elsewhere, the script stops
with an error rather than attaching you to the wrong workspace.

On first run for a given directory, this creates a container
from `claude-base-image` (4 CPUs / 16GB RAM by default) and mounts
`project_directory` as a disk device at `/workspace`. Every run
(including reuses) re-reads `.env` and pushes each key into the
container's environment via `incus config set`, so credential changes
take effect without recreating the container. It then execs into the
container and starts `claude` in `/workspace`.

## Tear down containers

```bash
pixi run remove-all-containers claude
```

Lists the **running** containers for one harness — matched on the
`claude--` name prefix the launcher uses — and deletes them after you
confirm. The argument is optional; omitting it targets every running
incus container, including any not created by this repo:

```bash
pixi run remove-all-containers          # everything running
pixi run remove-all-containers claude   # just Claude Code containers
```

The same filter will cover `copilot`, `opencode`, `codex` and friends
once their launchers land, since it keys off the shared
`<harness>--<directory>-<hash>` naming rather than a hardcoded list.

Pass `--yes` to skip the prompt; without a terminal (CI, a pipe) the
script refuses rather than deleting unattended. Stopped containers are
left alone; delete those individually with `incus delete <name>`.

## Notes

- The workspace disk device is mounted **without** `shift=true`. Some
  incus-on-macOS setups (virtiofs/FUSE-backed host sharing on a Linux
  6.8 guest kernel) don't support idmapped mounts, which makes
  `shift=true` fail with `Required idmapping abilities not available`.
  Without it, container root maps directly to your host user for that
  mount and read/write works fine.
- `.env` is only ever pushed into container config (`incus config`),
  never baked into the published image — the image build step doesn't
  touch it.
