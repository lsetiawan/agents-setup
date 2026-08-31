# LiteLLM proxy

A local [LiteLLM](https://docs.litellm.ai/) proxy, modelled on the LiteLLM half
of [uw-ssec/llmoxie](https://github.com/uw-ssec/llmoxie/tree/main/docker)
without MLflow, MinIO, Qdrant or Azurite.

It is a shim rather than a gateway of its own: Anthropic traffic is forwarded to
an upstream LiteLLM gateway that holds the real provider credentials, and the
local proxy rewrites the friendly model names agents send (`claude-opus-5`) onto
the upstream's own names (`cloudbank-claude-opus-5`). What you get locally is a
single endpoint in front of both that gateway and your own oMLX models, plus
spend logs, virtual keys and the admin UI backed by a local Postgres.

Unlike the agent setups in this repo, the proxy runs directly on the host under
pixi — there is no Docker here, and the proxy needs to reach oMLX on loopback.

## Usage

```bash
pixi run litellm        # starts Postgres, then the proxy in the foreground
pixi run stop-litellm   # stops the proxy and Postgres
```

The proxy listens on `http://127.0.0.1:4000`, with the admin UI at `/ui`. Set
`LITELLM_PORT` or `POSTGRES_PORT` to move either off its default.

The first run is slow: it initialises a Postgres cluster, generates the Prisma
client (the published LiteLLM container bakes this in at image build time; a PyPI
install has to do it once), and applies LiteLLM's schema migrations. Later starts
take about fifteen seconds.

Postgres keeps running after you `Ctrl-C` the proxy, so restarts are quick. Its
cluster lives in `.litellm/pgdata` (gitignored); delete that directory to start
from an empty database. If pixi ever rebuilds the environment, the Prisma client
goes with it and the next start regenerates it.

## Configuration

Credentials come from `.env`, read from the directory you invoke the task in and
falling back to the repo root — the same rule `start_claude_vm.sh` uses. Copy
`.env-example` to `.env` and fill it in; the variables that matter here:

| Variable | Purpose |
| --- | --- |
| `LITELLM_MASTER_KEY` | Key clients present to this proxy. Required. |
| `LITELLM_UPSTREAM_BASE_URL` | Upstream gateway. Defaults to `ANTHROPIC_BASE_URL`. |
| `LITELLM_UPSTREAM_API_KEY` | Upstream key. Defaults to `ANTHROPIC_AUTH_TOKEN`. |
| `DATABASE_URL` | Defaults to the local cluster in `.litellm/pgdata`. |
| `OMLX_API_BASE` | oMLX endpoint, e.g. `http://127.0.0.1:8999/v1`. |
| `OMLX_API_KEY` | oMLX key. |

Models are declared in [`config.yaml`](config.yaml) — the three upstream Claude
models and whichever oMLX models the local server hosts. `store_model_in_db` is
on, so models added through the admin UI persist in Postgres alongside the ones
in that file. Ask oMLX what it is serving before adding an entry:

```bash
curl "$OMLX_API_BASE/models" -H "Authorization: Bearer $OMLX_API_KEY"
```

### A note on reasoning models

Claude Opus 5 and both Qwen models think before they answer, and those thinking
tokens count against `max_tokens`. Ask for too few and the reply comes back
truncated with an empty `content` — `stop_reason: max_tokens` rather than an
error, so it looks like the model returned nothing. Give them room. The Qwen
models return their reasoning separately in `reasoning_content`.

### Pointing agents at the proxy

To route the agent containers through it, set in the project's `.env`:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:4000
ANTHROPIC_AUTH_TOKEN=<LITELLM_MASTER_KEY>
```

That is the same pair the proxy falls back to for its own upstream, so once you
do this you **must** also set `LITELLM_UPSTREAM_BASE_URL` and
`LITELLM_UPSTREAM_API_KEY` explicitly — otherwise the proxy would forward to
itself. `start_litellm.sh` refuses to start rather than loop if you forget.

Containers reach the host at `192.168.64.1`, not `127.0.0.1`, so a containerised
agent wants `http://192.168.64.1:4000` and a proxy started with
`--host 0.0.0.0`.

### oMLX from a container

oMLX listening on `127.0.0.1:8999` is unreachable from any container. Bind it to
`0.0.0.0` and use `http://192.168.64.1:8999/v1` if the proxy ever moves off the
host.

## Checking it works

```bash
curl http://127.0.0.1:4000/health/liveliness
curl http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```
