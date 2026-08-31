#!/bin/bash

set -e

IMAGE_TEMPLATE="claude-base-image"

WORKSPACE="/workspace"
MAX_CPU="4"
MAX_RAM="16GB"
NAME_PREFIX="claude-"

# ~/.claude inside the container is a bind mount of a host directory, so state
# survives the container being deleted. CLAUDE_CONFIG_DIR points Claude Code at
# that path, which also pulls .claude.json inside the mount rather than leaving
# it in /root, where it would go down with the container.
CLAUDE_CONFIG_PATH="/root/.claude"
STATE_DEVICE="claude-state"

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

SETTINGS_TEMPLATE="$REPO_ROOT/scripts/claude-code/claude-settings.json"

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
    echo ""
    echo "The container talks to the local LiteLLM proxy ('pixi run litellm'),"
    echo "never to the upstream gateway directly, so the proxy has to be running."
    echo ""
    echo "Environment overrides:"
    echo "  LITELLM_PORT    proxy port (default 4000)"
    echo "  AGENTS_HOST_IP  host address the container dials (default: discovered)"
    echo "  AGENTS_STATE_DIR  where per-project ~/.claude state is kept on the"
    echo "                  host (default: \$HOME/.agents-setup)"
    echo "=== Available Local Images ==="
    incus image list
    exit 0
    ;;
esac

# --- Credentials -----------------------------------------------------------

# The proxy's address and key are needed before any container exists, so read
# .env here as well as pushing it in below.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "Warning: $ENV_FILE not found; relying on the ambient environment." >&2
fi

: "${LITELLM_PORT:=4000}"

# Model names as the local proxy advertises them (see scripts/litellm/config.yaml).
# They are pushed as container environment rather than baked into the image's
# settings.json, because a settings.json "env" block would take precedence over
# them and silently pin the container to whatever the image was built with.
: "${ANTHROPIC_DEFAULT_OPUS_MODEL:=claude-opus-5}"
: "${ANTHROPIC_DEFAULT_SONNET_MODEL:=claude-sonnet-5}"
: "${ANTHROPIC_DEFAULT_HAIKU_MODEL:=claude-haiku-4-5}"
: "${ANTHROPIC_MODEL:=sonnet}"

if [ -z "$LITELLM_MASTER_KEY" ]; then
  echo "Error: LITELLM_MASTER_KEY is not set." >&2
  echo "       The container authenticates to the local proxy with it; set it in" >&2
  echo "       $ENV_FILE (see .env-example)." >&2
  exit 1
fi

# --- Proxy address ---------------------------------------------------------

# Containers cannot reach the host on loopback. They sit behind incusbr0 inside
# the Colima VM and NAT out of it, so they dial the host on the vmnet bridge the
# VM itself is attached to.
host_ip() {
  local vm_ip prefix ip

  if [ -n "$AGENTS_HOST_IP" ]; then
    echo "$AGENTS_HOST_IP"
    return 0
  fi

  vm_ip=$(colima status 2>&1 | sed -n 's/.*address: \([0-9][0-9.]*\).*/\1/p' | head -1)
  [ -n "$vm_ip" ] || return 1
  prefix="${vm_ip%.*}"

  # Prefer an address that actually exists on a host interface over assuming the
  # subnet's .1, but fall back to it if nothing matches.
  ip=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep "^${prefix}\." | grep -vx "$vm_ip" | head -1)
  echo "${ip:-${prefix}.1}"
}

if ! HOST_IP=$(host_ip) || [ -z "$HOST_IP" ]; then
  echo "Error: could not work out the host address the container should dial." >&2
  echo "       Is Colima running ('colima status')? Set AGENTS_HOST_IP to override." >&2
  exit 1
fi

PROXY_URL="http://$HOST_IP:$LITELLM_PORT"

# Fail here rather than letting Claude Code start and fail on its first request.
if ! curl -fsS -m 5 "http://127.0.0.1:$LITELLM_PORT/health/liveliness" >/dev/null 2>&1; then
  echo "Error: no LiteLLM proxy answering on port $LITELLM_PORT." >&2
  echo "       Start it in another terminal with 'pixi run litellm'." >&2
  exit 1
fi

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

# --- Persistent Claude state -----------------------------------------------

# Everything Claude Code keeps between runs - memory, projects, sessions,
# history, .claude.json - lives in one directory on the host, keyed the same way
# the container is. Deleting the container therefore does not take it along, and
# the next launch for this project picks up where the last one left off.
: "${AGENTS_STATE_DIR:=$HOME/.agents-setup}"
STATE_DIR="$AGENTS_STATE_DIR/claude/${CONTAINER_NAME#${NAME_PREFIX}-}"

# An empty directory counts as fresh too: that is what an interrupted first run
# leaves behind.
STATE_FRESH=0
if [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
  STATE_FRESH=1
fi

# Check if the container already exists
CONTAINER_EXISTED=0
if incus info "$CONTAINER_NAME" >/dev/null 2>&1; then
  CONTAINER_EXISTED=1
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

# --- Seed and attach the state directory -----------------------------------

mkdir -p "$STATE_DIR"

if [ "$STATE_FRESH" -eq 1 ]; then
  if [ "$CONTAINER_EXISTED" -eq 1 ]; then
    # The container predates this directory and has real history in its own
    # /root/.claude, which the mount below would hide. Copy it out first.
    echo "Adopting $CONTAINER_NAME's existing ~/.claude into $STATE_DIR"
    PULL_TMP=$(mktemp -d)
    if incus file pull -r "$CONTAINER_NAME/root/.claude" "$PULL_TMP" 2>/dev/null; then
      cp -R "$PULL_TMP/.claude/." "$STATE_DIR/"
    fi
    # .claude.json sits beside ~/.claude, not inside it, until CLAUDE_CONFIG_DIR
    # moves it in - so it has to be pulled separately.
    incus file pull "$CONTAINER_NAME/root/.claude.json" "$STATE_DIR/.claude.json" 2>/dev/null || true
    rm -rf "$PULL_TMP"
  fi

  # New containers, and older ones that never wrote settings of their own, start
  # from the same defaults the image bakes in. The mount hides the image's copy,
  # so it has to be seeded here.
  if [ ! -f "$STATE_DIR/settings.json" ] && [ -f "$SETTINGS_TEMPLATE" ]; then
    cp "$SETTINGS_TEMPLATE" "$STATE_DIR/settings.json"
  fi

  echo "Claude state for this project lives in $STATE_DIR"
fi

# Attach it, re-pointing an existing device if AGENTS_STATE_DIR has moved since
# the container was created. Unlike the workspace mount that is never a mistake
# worth erroring over - the override is always deliberate.
EXISTING_STATE=$(incus config device get "$CONTAINER_NAME" "$STATE_DEVICE" source 2>/dev/null || true)
if [ -n "$EXISTING_STATE" ] && [ "$EXISTING_STATE" != "$STATE_DIR" ]; then
  echo "Re-pointing Claude state from '$EXISTING_STATE' to '$STATE_DIR'"
  incus config device remove "$CONTAINER_NAME" "$STATE_DEVICE"
  EXISTING_STATE=""
fi
if [ -z "$EXISTING_STATE" ]; then
  incus config device add "$CONTAINER_NAME" "$STATE_DEVICE" disk \
        source="$STATE_DIR" path="$CLAUDE_CONFIG_PATH"
fi

# --- Container environment -------------------------------------------------

# Push the project's own .env through so tooling in the container sees it, minus
# the host-side halves of the proxy setup: the upstream gateway credentials, the
# spend database and the oMLX endpoint are the proxy's business, and the
# container has no use for them.
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    case "$key" in
      ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|LITELLM_*|DATABASE_URL|OMLX_*) continue ;;
    esac
    incus config set "$CONTAINER_NAME" "environment.$key=$value"
  done < "$ENV_FILE"
fi

# All model traffic goes through the local proxy, so the container is given the
# proxy's address and local key. The upstream gateway's own credentials stay on
# the host and never enter the sandbox.
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_BASE_URL=$PROXY_URL"
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_AUTH_TOKEN=$LITELLM_MASTER_KEY"
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_DEFAULT_OPUS_MODEL"
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_DEFAULT_SONNET_MODEL"
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_DEFAULT_HAIKU_MODEL"
incus config set "$CONTAINER_NAME" "environment.ANTHROPIC_MODEL=$ANTHROPIC_MODEL"

# Without this .claude.json is written to /root and lost with the container.
incus config set "$CONTAINER_NAME" "environment.CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_PATH"

# The proxy answers on the host; whether the container can route to it is a
# separate question (NAT, a host firewall), so check from the inside too. A
# freshly launched container needs a moment for its interface and DHCP lease,
# so retry rather than failing on the first attempt.
proxy_reachable() {
  local i
  for i in $(seq 1 30); do
    if incus exec "$CONTAINER_NAME" -- curl -fsS -m 5 "$PROXY_URL/health/liveliness" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! proxy_reachable; then
  echo "Error: $CONTAINER_NAME cannot reach the LiteLLM proxy at $PROXY_URL." >&2
  echo "       The proxy answers on the host, so this is a routing problem:" >&2
  echo "       check that it listens on 0.0.0.0 (the default) and that a host" >&2
  echo "       firewall is not blocking $HOST_IP:$LITELLM_PORT." >&2
  echo "       Set AGENTS_HOST_IP if the host is reachable at another address." >&2
  exit 1
fi

echo "Routing $CONTAINER_NAME through the LiteLLM proxy at $PROXY_URL"

# Enter the container session
incus exec "$CONTAINER_NAME" -- bash -c "cd ${WORKSPACE} && claude"
