#!/bin/bash

set -e

# Link `claude` inside the pixi environment to the container launcher, so an
# activated environment resolves `claude` to this repo's script instead of a
# host-installed Claude Code, without needing `pixi run claude`.

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/start_claude_vm.sh"

# CONDA_PREFIX points at the active pixi environment; fall back to the default
# one so this also works when run outside an activated shell.
ENV_PREFIX="${CONDA_PREFIX:-$REPO_ROOT/.pixi/envs/default}"
TARGET="$ENV_PREFIX/bin/claude"

if [ ! -x "$LAUNCHER" ]; then
  echo "Error: launcher $LAUNCHER not found or not executable." >&2
  exit 1
fi

if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  echo "Error: $TARGET already exists and is not a symlink." >&2
  echo "       Remove it first if you want the launcher to take its place." >&2
  exit 1
fi

mkdir -p "$(dirname "$TARGET")"
ln -sfn "$LAUNCHER" "$TARGET"

echo "Linked $TARGET -> $LAUNCHER"
echo "Start a new 'pixi shell' and 'claude' will launch the container."
