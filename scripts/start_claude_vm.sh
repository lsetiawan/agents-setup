#!/bin/bash

set -e

IMAGE_TEMPLATE="claude-base-image"

WORKSPACE="/workspace"
MAX_CPU="4"
MAX_RAM="16GB"
NAME_PREFIX="claude-"

# `pixi run claude` runs the task from the workspace root rather than from where
# it was invoked, but pixi exports INIT_CWD with the caller's directory.
INVOCATION_DIR="${INIT_CWD:-$(pwd)}"
# Resolve through symlinks: `pixi run setup-claude` links this script into the
# environment's bin/, and $0 is then that link rather than the real file.
REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"

# Credentials come from the directory the script was invoked in, falling back to
# the repo root so a single shared .env keeps working.
ENV_FILE="$INVOCATION_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
fi

case "$1" in
  -h|--help)
    echo "Usage: $0 <project_directory>(Optional)"
    echo ""
    echo "Project directory, and the .env read for credentials, default to the"
    echo "directory the script was invoked from."
    echo "The container name is derived from the directory, e.g. /path/to/work-dir"
    echo "maps to the container ${NAME_PREFIX}-work-dir-<hash>, so the same directory"
    echo "always reuses the same container while directories that share a basename"
    echo "each get their own."
    echo "=== Available Local Images ==="
    incus image list
    exit 0
    ;;
esac

TARGET_DIR="${1:-$INVOCATION_DIR}"

# Convert folder to absolute path and derive the container name from it, so the
# same project directory always maps back to the same container.
ABS_DIR=$(realpath "$TARGET_DIR")

if [ ! -d "$ABS_DIR" ]; then
  echo "Error: $ABS_DIR is not a directory." >&2
  exit 1
fi

# incus names allow only letters, digits and hyphens, and cap out at 63 chars.
DIR_NAME=$(basename "$ABS_DIR" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-')
DIR_NAME=$(echo "$DIR_NAME" | sed -e 's/-\{1,\}$//')

# Suffix a short hash of the full path so two directories sharing a basename
# (e.g. /a/work-dir and /b/work-dir) get their own containers.
if command -v shasum >/dev/null 2>&1; then
  DIR_HASH=$(printf '%s' "$ABS_DIR" | shasum -a 256 | cut -c1-4)
else
  DIR_HASH=$(printf '%s' "$ABS_DIR" | sha256sum | cut -c1-4)
fi

# 58 + "-" + 4 hash chars keeps us inside the 63-character limit.
BASE_NAME=$(echo "${NAME_PREFIX}-${DIR_NAME}" | cut -c1-58 | sed -e 's/-\{1,\}$//')
CONTAINER_NAME="${BASE_NAME}-${DIR_HASH}"

# Check if the container already exists
if incus info "$CONTAINER_NAME" >/dev/null 2>&1; then
  # Reuse it only if it is already bound to this exact directory.
  EXISTING_DIR=$(incus config device get "$CONTAINER_NAME" workspace source 2>/dev/null || true)
  if [ "$EXISTING_DIR" != "$ABS_DIR" ]; then
    echo "Error: container $CONTAINER_NAME already exists but is mounted at" >&2
    echo "       '${EXISTING_DIR:-<none>}', not '$ABS_DIR'." >&2
    echo "       Rename or delete that container, or rename this directory." >&2
    exit 1
  fi
  echo "Reusing existing container $CONTAINER_NAME for $ABS_DIR"

  # It may have been stopped (host reboot, `incus stop`, ...); bring it back up.
  if [ "$(incus info "$CONTAINER_NAME" | awk '/^Status:/ {print tolower($2)}')" != "running" ]; then
    incus start "$CONTAINER_NAME"
  fi
else
  # Create it only if it does not exist using the specified image
  incus launch $IMAGE_TEMPLATE "$CONTAINER_NAME" \
    -c limits.cpu=${MAX_CPU} \
    -c limits.memory=${MAX_RAM}

  incus config device add "$CONTAINER_NAME" \
        workspace disk source="$ABS_DIR" path=$WORKSPACE
fi

# Copy .env credentials (e.g. ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN) into the
# container's environment so `claude` picks them up on launch.
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    incus config set "$CONTAINER_NAME" "environment.$key=$value"
  done < "$ENV_FILE"
else
  echo "Warning: $ENV_FILE not found; skipping credential setup." >&2
fi

# Enter the container session
incus exec "$CONTAINER_NAME" -- bash -c "cd ${WORKSPACE} && claude"
