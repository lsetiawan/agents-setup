#!/bin/bash

set -e

LITELLM_PORT="${LITELLM_PORT:-4000}"
PG_PORT="${POSTGRES_PORT:-5432}"
PG_USER="${POSTGRES_USER:-litellm}"
PG_DB="${POSTGRES_DB:-litellm_db}"

# `pixi run litellm` runs the task from the workspace root rather than from where
# it was invoked, but pixi exports INIT_CWD with the caller's directory.
INVOCATION_DIR="${INIT_CWD:-$(pwd)}"
# Resolve through symlinks so the script still finds its own repo when it has
# been linked into the pixi environment's bin/.
REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"

CONFIG="$REPO_ROOT/scripts/litellm/config.yaml"
STATE_DIR="$REPO_ROOT/.litellm"
PGDATA="$STATE_DIR/pgdata"
PG_SOCKET_DIR="$STATE_DIR/sockets"
PG_LOG="$STATE_DIR/postgres.log"

case "$1" in
  -h|--help)
    echo "Usage: $0"
    echo ""
    echo "Starts a local Postgres and the LiteLLM proxy in the foreground."
    echo "Credentials are read from .env in the directory this was invoked from,"
    echo "falling back to a repo-root .env."
    echo ""
    echo "Environment overrides:"
    echo "  LITELLM_PORT   proxy port (default 4000)"
    echo "  POSTGRES_PORT  database port (default 5432)"
    echo ""
    echo "Stop the database again with 'pixi run stop-litellm'."
    exit 0
    ;;
esac

# --- Credentials -----------------------------------------------------------

ENV_FILE="$INVOCATION_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
fi

if [ -f "$ENV_FILE" ]; then
  echo "Reading credentials from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "Warning: no .env found; relying on the ambient environment." >&2
fi

# This proxy forwards Anthropic traffic to an upstream LiteLLM gateway rather
# than to Anthropic directly. The upstream defaults to whatever the agent
# containers already use, so a .env that predates this script keeps working.
: "${LITELLM_UPSTREAM_BASE_URL:=$ANTHROPIC_BASE_URL}"
: "${LITELLM_UPSTREAM_API_KEY:=$ANTHROPIC_AUTH_TOKEN}"
export LITELLM_UPSTREAM_BASE_URL LITELLM_UPSTREAM_API_KEY

if [ -z "$LITELLM_UPSTREAM_BASE_URL" ] || [ -z "$LITELLM_UPSTREAM_API_KEY" ]; then
  echo "Error: no upstream gateway configured." >&2
  echo "       Set LITELLM_UPSTREAM_BASE_URL and LITELLM_UPSTREAM_API_KEY in $ENV_FILE," >&2
  echo "       or leave ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN set to inherit them." >&2
  exit 1
fi

# Once ANTHROPIC_BASE_URL is repointed at this proxy so agents route through it,
# inheriting it as the upstream would make the proxy call itself.
case "$LITELLM_UPSTREAM_BASE_URL" in
  *localhost:"$LITELLM_PORT"*|*127.0.0.1:"$LITELLM_PORT"*|*0.0.0.0:"$LITELLM_PORT"*)
    echo "Error: the upstream gateway points back at this proxy on port $LITELLM_PORT." >&2
    echo "       That would loop. Set LITELLM_UPSTREAM_BASE_URL to the real upstream" >&2
    echo "       gateway in $ENV_FILE, alongside the ANTHROPIC_BASE_URL agents use." >&2
    exit 1
    ;;
esac

: "${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in $ENV_FILE}"
: "${DATABASE_URL:=postgresql://$PG_USER@127.0.0.1:$PG_PORT/$PG_DB}"
export DATABASE_URL

# --- Postgres --------------------------------------------------------------

mkdir -p "$STATE_DIR" "$PG_SOCKET_DIR"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "Initialising a new Postgres cluster in $PGDATA"
  # trust auth: the cluster listens on loopback only and holds nothing but
  # local spend logs, so there is no password to keep in sync with .env.
  initdb --pgdata="$PGDATA" --username="$PG_USER" --auth=trust >/dev/null
fi

if pg_ctl --pgdata="$PGDATA" status >/dev/null 2>&1; then
  echo "Postgres already running on port $PG_PORT"
else
  echo "Starting Postgres on port $PG_PORT"
  pg_ctl --pgdata="$PGDATA" --log="$PG_LOG" --wait \
    --options="-p $PG_PORT -k $PG_SOCKET_DIR -h 127.0.0.1" start
fi

if ! psql --host=127.0.0.1 --port="$PG_PORT" --username="$PG_USER" \
     --dbname=postgres --tuples-only --no-align \
     --command="SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1; then
  echo "Creating database $PG_DB"
  createdb --host=127.0.0.1 --port="$PG_PORT" --username="$PG_USER" "$PG_DB"
fi

# --- Prisma client ---------------------------------------------------------

# The published LiteLLM container generates the Prisma client at image build
# time. Installed from PyPI it has to be generated once against the schema that
# ships with litellm_proxy_extras, or the proxy cannot reach the database.
if ! python -c 'from prisma import Prisma' >/dev/null 2>&1; then
  SCHEMA=$(python -c 'import pathlib, litellm_proxy_extras; print(pathlib.Path(litellm_proxy_extras.__file__).parent / "schema.prisma")')
  echo "Generating the Prisma client from $SCHEMA (first run only)"
  prisma generate --schema "$SCHEMA" >/dev/null
fi

# --- Proxy -----------------------------------------------------------------

echo "Upstream gateway: $LITELLM_UPSTREAM_BASE_URL"
echo "Starting LiteLLM on http://127.0.0.1:$LITELLM_PORT (admin UI at /ui)"
echo "Postgres stays up after this exits; stop it with 'pixi run stop-litellm'."

exec litellm --config "$CONFIG" --port "$LITELLM_PORT"
