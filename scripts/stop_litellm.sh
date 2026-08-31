#!/bin/bash

set -e

LITELLM_PORT="${LITELLM_PORT:-4000}"

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
PGDATA="$REPO_ROOT/.litellm/pgdata"

case "$1" in
  -h|--help)
    echo "Usage: $0"
    echo ""
    echo "Stops the LiteLLM proxy and the local Postgres it writes spend logs to."
    echo "The database files under .litellm/pgdata are left in place; delete that"
    echo "directory to start from an empty cluster."
    exit 0
    ;;
esac

# start_litellm.sh runs the proxy in the foreground, so it is usually already
# gone by the time this runs. Clean up anything still holding the port.
PROXY_PIDS=$(lsof -t -nP -iTCP:"$LITELLM_PORT" -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$PROXY_PIDS" ]; then
  echo "Stopping LiteLLM on port $LITELLM_PORT"
  # shellcheck disable=SC2086
  kill $PROXY_PIDS
else
  echo "No LiteLLM proxy listening on port $LITELLM_PORT"
fi

if [ -d "$PGDATA" ] && pg_ctl --pgdata="$PGDATA" status >/dev/null 2>&1; then
  echo "Stopping Postgres"
  pg_ctl --pgdata="$PGDATA" --wait stop
else
  echo "No Postgres cluster running in $PGDATA"
fi
