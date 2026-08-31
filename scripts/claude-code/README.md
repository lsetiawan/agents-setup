# Claude Code incus scripts

Builds a minimal Alpine incus image with Claude Code preinstalled, and
launches per-project containers from it with your project directory
mounted in. Containers reach models through the local LiteLLM proxy
rather than the upstream gateway, so the gateway credentials stay on the
host.

## Prerequisites

- [incus](https://linuxcontainers.org/incus/) installed and initialized
  (`incus admin init`)
- The [LiteLLM proxy](../litellm/README.md) running (`pixi run litellm`).
  Containers talk to it, not to the upstream gateway, so the launcher
  refuses to start without it.
- A `.env` file with your credentials (copy `.env-example` and fill it
  in). The launcher reads it from the directory you invoke it in, and
  falls back to the repo root if that directory has none:

  ```
  ANTHROPIC_BASE_URL=...    # the upstream gateway, used by the proxy
  ANTHROPIC_AUTH_TOKEN=...  # its key — never enters a container
  LITELLM_MASTER_KEY=...    # what the container authenticates with
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

That also means you can run the task from any directory on the machine,
not just from inside this repo, by pointing pixi at the manifest:

```bash
pixi run --manifest-path /path/to/agents-setup/pixi.toml claude
```

`INIT_CWD` still points at wherever you invoked it, so the container
mounts that project and picks up its `.env`. Worth an alias:

```bash
alias cc='pixi run --manifest-path /path/to/agents-setup/pixi.toml claude'
```

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
container's environment via `incus config set`, so changes take effect
without recreating the container. It then execs into the container and
starts `claude` in `/workspace`.

## Persistent state

Containers are disposable; what Claude Code builds up inside them is
not. Each project gets a directory on the host —
`${AGENTS_STATE_DIR:-$HOME/.agents-setup}/claude/<project>-<hash>` —
mounted into the container at `/root/.claude` as the `claude-state` disk
device. Delete the container and relaunch, and memory, `projects/`,
`sessions/`, `history.jsonl` and `plugins/` are all still there.

The key is `<project>-<hash>`: the container name minus its `claude--`
prefix. Mapping a directory to its state therefore uses the same
derivation that maps a directory to its container, so the two never
drift apart.

The launcher also sets `CLAUDE_CONFIG_DIR=/root/.claude`. Left alone,
Claude Code writes `.claude.json` — MCP servers, per-project history,
onboarding state — to `/root/.claude.json`, *beside* the mount rather
than inside it, where it would go down with the container. Pointing
`CLAUDE_CONFIG_DIR` at the mount pulls that file in. It is a directory
mount for the same reason: `.claude.json` is rewritten by renaming a
temporary file over it, which a single-file bind mount would break.

### Seeding

The first launch for a directory creates the state directory and seeds
it:

- If the container already exists — it predates this feature, or you
  cleared the state directory — its current `/root/.claude` and
  `/root/.claude.json` are copied out to the host first, so mounting
  over them doesn't hide history that is already there.
- Otherwise `claude-settings.json` is copied in as `settings.json`. The
  image bakes the same file into `/root/.claude`, but the mount hides
  it, so the host side needs its own copy.

Later launches leave the directory's contents alone. An existing but
empty directory still counts as fresh, since that's what an interrupted
first run leaves behind.

Change `AGENTS_STATE_DIR` and the next launch seeds the new location
from the container's current `~/.claude` — which is still the old
directory at that point, since seeding happens before the device is
swapped — then re-attaches `claude-state` at the new path, printing what
it did. The old directory is copied, not moved; delete it yourself once
you're satisfied the move took.

### Removing state

`pixi run remove-all-containers` deletes containers, not state; keeping
it on the host is the whole point. To throw a project's history away:

```bash
rm -rf ~/.agents-setup/claude/<project>-<hash>
```

State directories accumulate — nothing prunes them for you.

## Model routing

The container never sees the upstream gateway. The launcher sets its
`ANTHROPIC_BASE_URL` to the local LiteLLM proxy and its
`ANTHROPIC_AUTH_TOKEN` to `LITELLM_MASTER_KEY`, so the real gateway key
stays on the host and all container spend lands in the proxy's logs.

Because of that, the `.env` push skips the keys that are the proxy's
business rather than the container's: `ANTHROPIC_BASE_URL`,
`ANTHROPIC_AUTH_TOKEN`, `LITELLM_*`, `DATABASE_URL` and `OMLX_*`.
Everything else in `.env` still goes through.

Containers cannot reach the host on loopback — they sit behind
`incusbr0` inside the Colima VM and NAT out of it. The launcher works
out the host's address on the vmnet bridge (`192.168.64.1` on a default
Colima setup) from `colima status`, confirms it against a real host
interface, and hands the container that. Set `AGENTS_HOST_IP` to
override it and `LITELLM_PORT` if the proxy is not on 4000.

Before launching, the script checks the proxy answers on the host, and
after starting the container it checks again from inside it — retrying
for up to 30 seconds, since a fresh container needs a moment for its
DHCP lease. Both failures print what to fix rather than letting Claude
Code start and fail on its first request.

Model names are pushed in as `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`,
defaulting to the names the proxy advertises (`claude-opus-5`,
`claude-sonnet-5`, `claude-haiku-4-5`); `ANTHROPIC_MODEL` defaults to
`sonnet`. Override any of them in `.env`. They are deliberately not in
the image's `settings.json`: a settings `env` block takes precedence
over the pushed environment, so names baked there would silently win.

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

- The workspace and `claude-state` disk devices are mounted **without**
  `shift=true`. Some
  incus-on-macOS setups (virtiofs/FUSE-backed host sharing on a Linux
  6.8 guest kernel) don't support idmapped mounts, which makes
  `shift=true` fail with `Required idmapping abilities not available`.
  Without it, container root maps directly to your host user for that
  mount and read/write works fine.
- `.env` is only ever pushed into container config (`incus config`),
  never baked into the published image — the image build step doesn't
  touch it.
- `claude-settings.json` holds only harness settings, no model names or
  credentials, so the image stays independent of whatever gateway or
  proxy you point it at.
