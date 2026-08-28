#!/bin/bash

set -e

IMAGE_TEMPLATE="claude-base-image"

WORKSPACE="/workspace"
MAX_CPU="4"
MAX_RAM="16GB"
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"

# Argument check
if [ -z "$1" ]; then
  echo "Error: Missing arguments." >&2
  echo "Usage: $0 <container_name> <project_directory>(Optional)" >&2
  echo ""
  echo "Project directory defaults to the current working directory if not specified."
  echo "=== Available Local Images ==="
  incus image list
  exit 1
fi

CONTAINER_NAME="$1"
TARGET_DIR="${2:-$(pwd)}"

# Convert folder to absolute path and extract its folder name for the container
ABS_DIR=$(realpath "$TARGET_DIR")

# Check if the container already exists
if ! incus info "$CONTAINER_NAME" >/dev/null 2>&1; then
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
