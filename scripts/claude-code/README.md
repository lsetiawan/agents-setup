# Claude Code incus scripts

Builds a minimal Alpine incus image with Claude Code preinstalled, and
launches per-project containers from it with your project directory
mounted in and API credentials injected at startup.

## Prerequisites

- [incus](https://linuxcontainers.org/incus/) installed and initialized
  (`incus admin init`)
- A `.env` file at the repo root with your credentials (copy
  `.env-example` and fill it in):

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

From the repo root:

```bash
./start_claude_vm.sh <container_name> [project_directory]
```

- `container_name` — name for the incus container. If it already
  exists, the script reuses it instead of creating a new one.
- `project_directory` — host directory to mount into the container at
  `/workspace`. Defaults to the current working directory.

On first run for a given `container_name`, this creates a container
from `claude-base-image` (4 CPUs / 16GB RAM by default) and mounts
`project_directory` as a disk device at `/workspace`. Every run
(including reuses) re-reads `.env` and pushes each key into the
container's environment via `incus config set`, so credential changes
take effect without recreating the container. It then execs into the
container and starts `claude` in `/workspace`.

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
