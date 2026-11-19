#!/usr/bin/env bash
# fass docker install — one-time setup of a machine (the host folders, the
# web UI port, the http stream port, and — when the user wants one — the
# LLM endpoint, its API key and its model name, plus the database — the
# default fass-db container or a custom one — are the install-time
# questions; everything else is tuned in the web GUI).
#
#   ./setup.sh                                  # interactive prompts
#   ./setup.sh --yes                            # accept the defaults
#   ./setup.sh --yes --input /srv/in --output /srv/out --log /srv/log
#   ./setup.sh --config /srv/config             # move the config folder
#   ./setup.sh --yes --ui-port 9000             # the web UI host port
#   ./setup.sh --yes --http-port 9090           # the http stream sidecar port
#   ./setup.sh --yes --bind 0.0.0.0             # serve on all interfaces
#                                               # (the default 127.0.0.1 is
#                                               # local only)
#   ./setup.sh --yes --no-llm                   # fass without an LLM
#   ./setup.sh --yes --llm http://192.168.0.9:8080 --api-key sk-... --model my-model
#   ./setup.sh --yes --llm http://192.168.0.9:8080 --timeout 30
#   ./setup.sh --yes --gpu-pin 1                # fass's ffmpeg on GPU 1
#   ./setup.sh --upgrade                        # an older fass install is on
#                                               # the machine: remove its
#                                               # containers instead of asking
#   ./setup.sh --remove                     # stop and remove the fass
#                                           # stack (every container +
#                                           # the network) — data is kept
#
# Linux only: Windows and macOS are not supported — the deployment is a
# Linux Docker stack with the NVIDIA runtime. setup.sh refuses to start
# on anything but Linux (WSL2 counts: it is Linux).
#
# Docker is a hard requirement: setup.sh aborts (before asking anything)
# if the docker CLI, the compose plugin, or a reachable daemon is missing.
# The machine must also have at least 2 GB of free (available) RAM.
#
# The deployment is the published image boris271142/fass (Docker Hub) —
# compiled, FFmpeg 9 + NVIDIA acceleration; there is nothing to build on
# this machine. setup.sh creates the host folders mounted as /input,
# /output, /log (sources, results, run logs) and the config folder
# (/config), asks for the web UI port (default 8000), the http stream
# port (the fass-http sidecar serving HLS/DASH runs, default 8001 — 8080
# is often taken by local LLM servers), the bind address — 127.0.0.1
# (local only, the default) or 0.0.0.0 (all interfaces; on 0.0.0.0 the
# final messages remind to set the API key in the Config tab after the
# install is done and which ports to open in the firewall) — and
# whether fass will use an LLM at all; when yes, for the LLM base URL
# (OpenAI-compatible endpoint),
# the API key (empty = not required) and the model name. It then asks
# for the database: the default is the fass-db pgvector container this
# compose file starts; a custom answer asks for the db host, port, user
# name, password and name one by one; a custom database skips starting
# the local fass-db service. On a re-run the saved db section and the
# install's current ports are the prompt defaults. Then it pulls the
# image and starts the stack.
# The LLM connection timeout is NOT asked —
# it defaults to 10 s in the image and is tuned in the Config tab. With
# python on the machine, scripts/port_probe.py checks both ports for
# availability (bind test) and probes the LLM endpoint for reachability;
# without python no probing happens and config.json is seeded by the
# container entrypoint on first boot instead of by setup.sh.
#
# GPU: probes nvidia-smi, and when the nvidia-smi binary is absent the
# python scripts/gpu_probe.py lists the cards from /proc/driver/nvidia/gpus
# (the nvidia kernel module exposes one directory per card even without
# the toolkit). Without a GPU the deployment is CPU-only: no device
# reservation is written at all and the container gets FASS_GPU_PROBE=0,
# so GPU-involved ffmpeg commands are GENERATED (argv/CLI) but REFUSED at
# execution (start_run raises 403) — see the Execution section of
# docker/README.md — and the final messages say so. On a multi-GPU
# machine the interactive prompt offers the found cards (default 0);
# --gpu-pin N picks the card fass's ffmpeg encodes on; a non-zero pin also
# exposes index 0 to the container (a required NVENC workaround — see
# compose.yaml). When a GPU is found the final messages explain how to
# change the card later (FASS_GPU_PIN in docker/.env +
# ./scripts/web.sh restart).
#
# The folders are recorded in two places so they stay in sync:
#   docker/.env            — compose reads it at every `up` (git-ignored,
#                            machine-local; the compose file interpolates
#                            ${FASS_INPUT_DIR} etc. with repo-relative
#                            defaults)
#   <config>/config.json   — the volumes section, which the Config tab
#                            shows and the Apply button re-creates the
#                            container from
# After install the Config tab OWNS the paths: Apply re-creates from
# config.json, and scripts/web.sh re-syncs docker/.env from config.json
# before every compose up — so paths changed in the UI survive restarts.
set -euo pipefail

# Linux only — the deployment is a Linux Docker stack (the GPU path uses
# the NVIDIA runtime). Windows and macOS are not supported: no build for
# them exists, and there is nothing to fall back to.
case "$(uname -s)" in
  Linux) ;;
  Darwin)
    echo "error: fass is not supported on macOS — it is a Linux deployment (Docker stack with the NVIDIA runtime)." >&2
    echo "Use a Linux machine, VM or cloud instance." >&2
    exit 1 ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    echo "error: fass is not supported on Windows — it is a Linux deployment (Docker stack with the NVIDIA runtime)." >&2
    echo "Use a Linux machine, VM or cloud instance (WSL2 works: it is Linux)." >&2
    exit 1 ;;
  *)
    echo "error: unsupported operating system '$(uname -s)' — fass is Linux only (Docker stack with the NVIDIA runtime)." >&2
    exit 1 ;;
esac

# Docker is a hard requirement — the deployment IS the Docker stack. Abort
# before asking anything: the CLI must be installed, the daemon reachable
# from this user (setup.sh never uses sudo), and the compose plugin present
# (the stack is started with `docker compose`).
command -v docker >/dev/null 2>&1 \
  || { echo "error: docker not found — install Docker (https://docs.docker.com/get-docker/) and re-run setup.sh." >&2; exit 1; }
docker compose version >/dev/null 2>&1 \
  || { echo "error: the docker compose plugin is missing — install docker-compose-plugin and re-run setup.sh." >&2; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "error: the docker daemon is not reachable from this user — start Docker (e.g. sudo systemctl start docker) and/or add your user to the docker group, then re-run setup.sh." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/docker" && pwd)"
REPO="$(dirname "$DIR")"
IMAGE="boris271142/fass:latest"
RAG_IMAGE="boris271142/fass-rag:latest"

INPUT="${FASS_INPUT_DIR:-$REPO/media/input}"
OUTPUT="${FASS_OUTPUT_DIR:-$REPO/media/output}"
LOG="${FASS_LOG_DIR:-$REPO/media/log}"
CONFIG="${FASS_CONFIG_DIR:-$REPO/docker-data/config}"
UI_PORT=8000
UI_PORT_SET=0
LLM_URL=""
API_KEY=""
LLM_MODEL=""
LLM_OFF=0
LLM_TIMEOUT="10"
TIMEOUT_SET=0
HTTP_PORT=8001
HTTP_PORT_SET=0
BIND="127.0.0.1"
BIND_SET=0
GPU_PIN="${FASS_GPU_PIN:-0}"
GPU_PIN_SET=0
ASSUME=0
UPGRADE=0
REMOVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)  INPUT="$2";  shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --log)    LOG="$2";    shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --llm)    LLM_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --ui-port) UI_PORT="$2"; UI_PORT_SET=1; shift 2 ;;
    --timeout) LLM_TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    --http-port) HTTP_PORT="$2"; HTTP_PORT_SET=1; shift 2 ;;
    --bind)    BIND="$2"; BIND_SET=1; shift 2 ;;
    --model)   LLM_MODEL="$2"; shift 2 ;;
    --no-llm)  LLM_OFF=1; shift ;;
    --gpu-pin)  GPU_PIN="$2"; GPU_PIN_SET=1; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --remove)  REMOVE=1; shift ;;
    -y|--yes) ASSUME=1; shift ;;
    -h|--help) sed -n "2,$(( $(grep -n '^set -euo pipefail' "$0" | head -1 | cut -d: -f1) - 1 ))p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if (( LLM_OFF )) && [[ -n "$LLM_URL" ]]; then
  echo "error: use either --llm <url> or --no-llm, not both" >&2; exit 2
fi

# --- remove -----------------------------------------------------------------
# ./setup.sh --remove — stop and remove the whole fass stack: the
# containers of THIS install (compose down: the app, the worker, the RAG
# and the http sidecar, the default fass-db and the stack network) plus
# the leftover fixed-name fass containers of an older install from another
# directory (the same collision rule as the upgrade detection below).
# Only the containers go: the data (config, database contents, media),
# the images and docker/.env are kept — re-run setup.sh to install on the
# existing data. This runs BEFORE the RAM check on purpose: the stack
# being removed is often what fills the memory. The removal is confirmed
# on a tty; --yes skips the question; off a tty without --yes it refuses
# (a destructive command must not run unconfirmed in a pipeline).
if (( REMOVE )); then
  COMPOSE=(docker compose -f "$DIR/compose.yaml")
  [[ -f "$DIR/compose.local.yaml" ]] && COMPOSE+=(-f "$DIR/compose.local.yaml")
  if (( ASSUME )); then
    ans="y"
  elif [[ -t 0 ]]; then
    echo "this stops and removes the fass stack — every fass container (the app,"
    echo "the worker, the RAG and the http sidecar, the default fass-db) and the"
    echo "stack network. The data is NOT touched: the config, the database"
    echo "contents, the media and the pulled images are kept — re-run setup.sh"
    echo "to install on the existing data."
    printf 'Remove the fass stack? [y/N]: '
    read -r ans || ans="n"
  else
    echo "error: --remove outside a tty needs --yes to confirm the removal." >&2
    exit 2
  fi
  case "${ans:-n}" in
    [yY]*) ;;
    *) echo "not removing anything — the fass stack was left untouched." >&2; exit 1 ;;
  esac
  echo "removing the fass stack (containers + network — the data is kept)"
  "${COMPOSE[@]}" down
  # compose covers only THIS directory's install: sweep the leftover
  # containers of an older install from another directory (it keeps the
  # same fixed container names — see the upgrade detection below)
  LEFT="$(docker ps -a --format '{{.Names}}' \
    | grep -E '^(fass|fass-db|fass-worker|fass-rag|fass-http|docker-fass-rag-1|docker-fass-worker-1|docker-fass-http-1)$' || true)"
  if [[ -n "$LEFT" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $LEFT
  fi
  echo "removed the fass stack — run setup.sh again to install (the data is kept)"
  exit 0
fi

# At least 2 GB of available RAM — the stack (ffmpeg, the sidecars, the LLM
# adapter) OOMs or thraps badly below that. MemAvailable counts reclaimable
# page cache, so memory that is used but reclaimable still counts as free.
FREE_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
[[ "$FREE_MB" =~ ^[0-9]+$ ]] \
  || { echo "error: could not read available memory from /proc/meminfo — cannot continue." >&2; exit 1; }
(( FREE_MB >= 2048 )) \
  || { echo "error: only ${FREE_MB} MB of RAM available — fass needs at least 2048 MB free." >&2; exit 1; }

# absolute paths, no need to exist yet (Docker requires absolute binds)
canon() { realpath -m -- "$1"; }
INPUT="$(canon "$INPUT")"; OUTPUT="$(canon "$OUTPUT")"
LOG="$(canon "$LOG")";     CONFIG="$(canon "$CONFIG")"

# The python interpreter, if any — scripts/port_probe.py probes the ports
# (bind test) and the LLM endpoint (connection), and the config.json
# read/seed below need an interpreter. Without python: no probing happens
# (a taken port then surfaces at `up`) and the container entrypoint
# seeds config.json on first boot.
PYBIN=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PYBIN="$c"; break; }
done

# GPU probe — the card list, one line per card: "GPU <i>: <name> ...".
# nvidia-smi -L when the toolkit binary is present and answers; otherwise
# the python scripts/gpu_probe.py, which reads /proc/driver/nvidia/gpus
# (the nvidia kernel module exposes one directory per card even without
# the nvidia-smi binary). Without nvidia-smi AND without python the cards
# cannot be listed — the install proceeds CPU-only.
GPU=0; GPU_COUNT=0; GPU_LIST=""
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  GPU_LIST="$(nvidia-smi -L)"
elif [[ -n "$PYBIN" ]] && "$PYBIN" "$REPO/scripts/gpu_probe.py" >/dev/null 2>&1; then
  GPU_LIST="$("$PYBIN" "$REPO/scripts/gpu_probe.py")"
fi
if [[ -n "$GPU_LIST" ]]; then
  GPU_COUNT="$(printf '%s\n' "$GPU_LIST" | grep -c .)"
  GPU=1
fi

# Which GPU fass's ffmpeg uses (host index, card-list order — nvidia-smi
# and the python probe both list in PCI topology order).
# Default 0 — correct on single-GPU hosts. The pin is recorded in
# docker/.env (FASS_GPU_PIN); a non-zero pin N additionally needs index 0
# exposed to the container (a container whose ONLY exposed device sits at
# a non-zero index breaks NVENC — see the device comment in
# docker/compose.yaml), which the local overlay below arranges.
# CUDA_VISIBLE_DEVICES is the IN-CONTAINER index, and devices keep their
# position in the exposure list (verified 2026-11-06: exposure ["0","2"]
# presents the host's GPU 2 as in-container GPU 1, and CVD=2 fails there):
# ["0"] -> the pinned card is in-container 0, ["0","N"] -> it is 1.
#
# The pin arrives from three sources at three points: --gpu-pin (parsed
# above), the docker/.env re-run inheritance just below, and the
# interactive ask further down — so the range check and the GPU_CVD
# computation are a function called after each merge (GPU_CVD depends
# on the FINAL pin).
gpu_check() {
  if [[ $GPU -eq 1 ]]; then
    if ! [[ "$GPU_PIN" =~ ^[0-9]+$ ]] || (( GPU_PIN >= GPU_COUNT )); then
      { echo "gpu pin must be a whole index between 0 and $((GPU_COUNT - 1)) (got: $GPU_PIN) — the detected cards:" >&2
        printf '%s\n' "$GPU_LIST" >&2
      }
      exit 2
    fi
    if (( GPU_PIN > 0 )); then GPU_CVD=1; else GPU_CVD=0; fi
  else
    GPU_CVD=0
  fi
}
# A re-run in an installed dir keeps the card the install picked (an
# explicit --gpu-pin overrides). Read HERE, before the first gpu_check:
# a hand-edited out-of-range FASS_GPU_PIN then fails before the upgrade
# detection below can have removed running containers.
if [[ $GPU_PIN_SET -eq 0 && -f "$DIR/.env" ]]; then
  ENV_GPU_PIN="$(sed -n 's/^FASS_GPU_PIN=//p' "$DIR/.env" | tail -1)"
  [[ -n "$ENV_GPU_PIN" ]] && GPU_PIN="$ENV_GPU_PIN"
fi
gpu_check

# --- existing fass install (upgrade detection) ------------------------------
# The stack uses FIXED container names (the compose container_name values):
# fass, fass-db, fass-worker, fass-rag, fass-http — plus the project-prefixed
# spellings source-tree deployments produce (docker-fass-rag-1, ...). An
# install from ANOTHER directory therefore collides with this one even while
# it is stopped: `up` would fail on the published ports or silently
# resurrect the old stopped containers. Containers started from THIS
# directory are our own (an in-place re-install) — compose handles those.
# With --upgrade the old containers are removed without asking; otherwise
# the script asks (remove or quit) on a tty and refuses off one.
# Only the CONTAINERS are removed — the old install's config/media folders
# and its images are kept (a fallback).
OLD_IDS=()
OLD_NAMES=()
MY_NAMES=()
while read -r id name; do
  [[ -n "$id" ]] || continue
  name="${name%%,*}"
  case "$name" in
    fass|fass-db|fass-worker|fass-rag|fass-http|docker-fass-rag-1|docker-fass-worker-1|docker-fass-http-1) ;;
    *) continue ;;
  esac
  wdir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id" 2>/dev/null || true)"
  [[ "$wdir" == "$DIR" ]] && { MY_NAMES+=("$name"); continue; }
  OLD_IDS+=("$id")
  OLD_NAMES+=("$name")
done < <(docker ps -a --format '{{.ID}} {{.Names}}')

if (( ${#OLD_IDS[@]} > 0 )); then
  remove_old() {
    echo "removing the old fass install — containers: ${OLD_NAMES[*]}"
    echo "kept: its config/media folders and the old images (only the containers go)"
    docker rm -f "${OLD_IDS[@]}"
  }
  if (( UPGRADE )); then
    echo "upgrade mode: an older fass install is on this machine"
    remove_old
  elif [[ -t 0 ]]; then
    echo
    echo "an older fass installation is already on this machine:"
    for id in "${OLD_IDS[@]}"; do
      echo "  - $(docker ps -a --no-trunc --filter "id=$id" --format '{{.Names}} ({{.State}})')"
    done
    printf 'Remove the old fass containers and upgrade, or quit? [u]pgrade / [q]uit [q]: '
    read -r ans || ans="q"
    case "${ans:-q}" in
      [uU]|[yY]*|upgrade) remove_old ;;
      *)
        echo "quitting — the old fass install was left untouched." >&2
        exit 1 ;;
    esac
  else
    echo "error: an older fass installation is on this machine (containers: ${OLD_NAMES[*]})" >&2
    echo "and its containers collide with this install." >&2
    echo "Re-run with --upgrade to remove the old fass containers and install the new" >&2
    echo "version (config/media folders and old images are kept), or remove them by hand." >&2
    exit 1
  fi
fi

CFGJSON="$CONFIG/config.json"
# defaults for the prompts: existing config wins, else the fresh-install
# defaults (the LLM base URL's host is the docker bridge gateway —
# 172.17.0.1 is the host, seen from the container — the container
# entrypoint seeds the same values on first boot)
LLM_HOST=""; LLM_PORT="8080"; CFG_API_KEY=""; CFG_MODEL=""; CFG_GPU="true"; CFG_TIMEOUT="10"; CFG_HTTP_PORT="8001"
CFG_DB_HOST=""; CFG_DB_PORT="5432"; CFG_DB_USER=""; CFG_DB_PASS=""; CFG_DB_NAME=""
if [[ -f "$CFGJSON" ]] && [[ -n "$PYBIN" ]]; then
  # one value per line (not space-joined): the model name and the API key
  # may be empty or contain spaces
  {
    read -r LLM_HOST
    read -r LLM_PORT
    read -r CFG_GPU
    read -r CFG_TIMEOUT
    read -r CFG_HTTP_PORT
    read -r CFG_MODEL
    read -r CFG_API_KEY
    read -r CFG_DB_HOST
    read -r CFG_DB_PORT
    read -r CFG_DB_USER
    read -r CFG_DB_PASS
    read -r CFG_DB_NAME
  } < <("$PYBIN" - "$CFGJSON" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
llm = cfg.get("llm") or {}
base = (cfg.get("streaming") or {}).get("http_base_url") or ""
port = 8001
if "://" in base:
    hostpart = base.split("://", 1)[1].rsplit("/", 1)[0]
    if ":" in hostpart:
        try:
            port = int(hostpart.rsplit(":", 1)[1])
        except ValueError:
            pass
db = cfg.get("db") or {}
for v in (llm.get("host") or "", llm.get("port") or 8080,
          str(bool((cfg.get("gpu") or {}).get("enabled", True))).lower(),
          (llm.get("timeout") or 10), port, llm.get("model") or "",
          llm.get("api_key") or "",
          db.get("host") or "", db.get("port") or 5432,
          db.get("user_name") or "", db.get("password") or "",
          db.get("database") or ""):
    print(v)
PYEOF
)
fi
# an existing config with a non-empty LLM host is a "was configured"
# answer for the LLM question below
CFG_LLM_SET=0
[[ -f "$CFGJSON" && -n "$LLM_HOST" ]] && CFG_LLM_SET=1
[[ -n "$LLM_HOST" ]] || LLM_HOST="172.17.0.1"
[[ -n "$LLM_URL" ]] || LLM_URL="http://$LLM_HOST:$LLM_PORT"
# --timeout wins over the saved config; the saved config wins over 10
[[ $TIMEOUT_SET -eq 0 ]] && LLM_TIMEOUT="$CFG_TIMEOUT"

# A re-run must not silently move the ports of the existing install: the
# ports it was started with (docker/.env) and the stream port the app
# serves at (the config's base URL) become the defaults, and so does the
# bind address it was started with; an explicit --ui-port/--http-port/
# --bind overrides them.
ENV_UI_PORT=""; ENV_HTTP_PORT=""; ENV_BIND=""
if [[ -f "$DIR/.env" ]]; then
  ENV_UI_PORT="$(sed -n 's/^FASS_UI_PORT=//p' "$DIR/.env" | tail -1)"
  ENV_HTTP_PORT="$(sed -n 's/^FASS_HTTP_PORT=//p' "$DIR/.env" | tail -1)"
  ENV_BIND="$(sed -n 's/^FASS_BIND=//p' "$DIR/.env" | tail -1)"
fi
if [[ $UI_PORT_SET -eq 0 && -n "$ENV_UI_PORT" ]]; then UI_PORT="$ENV_UI_PORT"; fi
if [[ $BIND_SET -eq 0 && -n "$ENV_BIND" ]]; then BIND="$ENV_BIND"; fi
if [[ $HTTP_PORT_SET -eq 0 ]]; then
  if [[ "$CFG_HTTP_PORT" != "8001" ]]; then HTTP_PORT="$CFG_HTTP_PORT"
  elif [[ -n "$ENV_HTTP_PORT" ]]; then HTTP_PORT="$ENV_HTTP_PORT"; fi
fi

# --- database ---------------------------------------------------------------
# The standard (default) database is the fass-db pgvector container this
# repo's compose file starts; a custom answer points fass at a database
# somewhere else. A saved db section counts as custom only when it
# differs from the standard values (a saved default is not custom).
DB_DEF_HOST="fass-db"; DB_DEF_PORT="5432"
DB_DEF_USER="ffmpeg"; DB_DEF_PASS="ffmpeg"; DB_DEF_NAME="ffmpeg_assisstant"
CFG_DB_CUSTOM=0
if [[ -n "$CFG_DB_HOST" && ( "$CFG_DB_HOST" != "$DB_DEF_HOST" || "$CFG_DB_PORT" != "$DB_DEF_PORT" ||
     "$CFG_DB_USER" != "$DB_DEF_USER" || "$CFG_DB_PASS" != "$DB_DEF_PASS" ||
     "$CFG_DB_NAME" != "$DB_DEF_NAME" ) ]]; then
  CFG_DB_CUSTOM=1
fi

if [[ $ASSUME -eq 0 ]]; then
  ask() { # ask() <label> <default> — Enter accepts the default
    local ans
    read -e -p "$1 [$2]: " ans || true
    printf '%s' "${ans:-$2}"
  }
  INPUT="$(ask  "input host folder"  "$INPUT")"
  OUTPUT="$(ask "output host folder" "$OUTPUT")"
  LOG="$(ask    "log host folder"    "$LOG")"
  CONFIG="$(ask "config host folder" "$CONFIG")"
  UI_PORT="$(ask   "web UI port" "$UI_PORT")"
  HTTP_PORT="$(ask "http stream port (HLS/DASH sidecar)" "$HTTP_PORT")"
  BIND="$(ask "serve fass on (0.0.0.0 = all interfaces, 127.0.0.1 = local only)" "$BIND")"
  if (( GPU == 1 && GPU_COUNT > 1 && GPU_PIN_SET == 0 )); then
    echo "found $GPU_COUNT GPUs:"
    printf '%s\n' "$GPU_LIST" | sed 's/^/  /'
    GPU_PIN="$(ask "GPU to use (index 0-$((GPU_COUNT - 1)))" "$GPU_PIN")"
  fi
  if (( LLM_OFF )); then
    LLM_SET=0
  else
    # default: yes on a fresh install or when the LLM was configured
    # before, no when a previous run chose "not configured"
    if (( CFG_LLM_SET )) || [[ ! -f "$CFGJSON" ]]; then LLM_DEFAULT="y"; else LLM_DEFAULT="n"; fi
    ans="$(ask "Configure an LLM for fass" "$LLM_DEFAULT")"
    case "$ans" in [yY]*) LLM_SET=1 ;; *) LLM_SET=0 ;; esac
  fi
  if (( LLM_SET )); then
    LLM_URL="$(ask "LLM base URL (OpenAI-compatible)" "$LLM_URL")"
    API_KEY="$(ask "LLM API key (empty = not required)" "$CFG_API_KEY")"
    [[ -n "$LLM_MODEL" ]] || LLM_MODEL="${CFG_MODEL:-qwen3.8-27b}"
    LLM_MODEL="$(ask "LLM model name" "$LLM_MODEL")"
  fi
  # the database: default (the fass-db container) or custom — a saved
  # custom db makes the default answer "n" so a re-run does not silently
  # flip the database
  DED="y"; (( CFG_DB_CUSTOM )) && DED="n"
  ans="$(ask "Use the default database (the fass-db pgvector container)" "$DED")"
  case "$ans" in
    [yY]*) DB_HOST="$DB_DEF_HOST"; DB_PORT="$DB_DEF_PORT"
           DB_USER="$DB_DEF_USER"; DB_PASS="$DB_DEF_PASS"
           DB_NAME="$DB_DEF_NAME" ;;
    *)
      if [[ -n "$CFG_DB_HOST" ]]; then
        # a saved db section: its values are the prompt defaults
        DB_HOST="$(ask "db host" "$CFG_DB_HOST")"
        DB_PORT="$(ask "db port" "$CFG_DB_PORT")"
        DB_USER="$(ask "db user name" "$CFG_DB_USER")"
        DB_PASS="$(ask "db password" "$CFG_DB_PASS")"
        DB_NAME="$(ask "db name" "$CFG_DB_NAME")"
      else
        DB_HOST="$(ask "db host" "$DB_DEF_HOST")"
        DB_PORT="$(ask "db port" "$DB_DEF_PORT")"
        DB_USER="$(ask "db user name" "$DB_DEF_USER")"
        DB_PASS="$(ask "db password" "$DB_DEF_PASS")"
        DB_NAME="$(ask "db name" "$DB_DEF_NAME")"
      fi ;;
  esac
else
  if (( LLM_OFF )); then
    LLM_SET=0
  elif [[ ! -f "$CFGJSON" ]]; then
    LLM_SET=1
  else
    LLM_SET=$CFG_LLM_SET
  fi
  if (( LLM_SET )); then
    [[ -n "$LLM_MODEL" ]] || LLM_MODEL="${CFG_MODEL:-qwen3.8-27b}"
  fi
  # non-interactive: a saved db section wins (re-run = untouched), a
  # fresh install gets the standard fass-db values
  if [[ -n "$CFG_DB_HOST" ]]; then
    DB_HOST="$CFG_DB_HOST"; DB_PORT="$CFG_DB_PORT"
    DB_USER="$CFG_DB_USER"; DB_PASS="$CFG_DB_PASS"; DB_NAME="$CFG_DB_NAME"
  else
    DB_HOST="$DB_DEF_HOST"; DB_PORT="$DB_DEF_PORT"
    DB_USER="$DB_DEF_USER"; DB_PASS="$DB_DEF_PASS"; DB_NAME="$DB_DEF_NAME"
  fi
fi
# the timeout is never asked — it is a config number (1..300 s) from
# --timeout or the saved config; the user tunes it in the Config tab
[[ "$LLM_TIMEOUT" =~ ^[0-9]+$ ]] && (( LLM_TIMEOUT >= 1 && LLM_TIMEOUT <= 300 )) \
  || { echo "LLM timeout must be a whole number of seconds between 1 and 300 (got: $LLM_TIMEOUT)" >&2; exit 2; }
for p in "$INPUT" "$OUTPUT" "$LOG" "$CONFIG"; do
  [[ "$p" == /* ]] || { echo "not an absolute path: $p" >&2; exit 2; }
done
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [[ "$HTTP_PORT" -ge 1 && "$HTTP_PORT" -le 65535 ]] \
  || { echo "http stream port must be a number 1-65535: $HTTP_PORT" >&2; exit 2; }
[[ "$UI_PORT" =~ ^[0-9]+$ ]] && [[ "$UI_PORT" -ge 1 && "$UI_PORT" -le 65535 ]] \
  || { echo "web UI port must be a number 1-65535: $UI_PORT" >&2; exit 2; }
[[ "$UI_PORT" != "$HTTP_PORT" ]] \
  || { echo "the web UI port and the http stream port must be different (both $UI_PORT)" >&2; exit 2; }
case "$BIND" in
  127.0.0.1|0.0.0.0) ;;
  *) echo "bind address must be 127.0.0.1 (local only) or 0.0.0.0 (all interfaces): $BIND" >&2; exit 2 ;;
esac
[[ "$DB_PORT" =~ ^[0-9]+$ ]] && [[ "$DB_PORT" -ge 1 && "$DB_PORT" -le 65535 ]] \
  || { echo "db port must be a number 1-65535: $DB_PORT" >&2; exit 2; }
[[ -n "$DB_HOST" ]] || { echo "db host must not be empty" >&2; exit 2; }
[[ -n "$DB_USER" ]] || { echo "db user name must not be empty" >&2; exit 2; }
[[ -n "$DB_NAME" ]] || { echo "db name must not be empty" >&2; exit 2; }
DB_IS_DEFAULT=0
if [[ "$DB_HOST" == "$DB_DEF_HOST" && "$DB_PORT" == "$DB_DEF_PORT" && "$DB_USER" == "$DB_DEF_USER" &&
      "$DB_PASS" == "$DB_DEF_PASS" && "$DB_NAME" == "$DB_DEF_NAME" ]]; then
  DB_IS_DEFAULT=1
fi

# --- port availability -------------------------------------------------------
# The stack publishes the web UI on $UI_PORT and the fass-http sidecar on
# $HTTP_PORT (fass-rag stays internal). Old-install containers are gone by
# now; containers of THIS install dir (an in-place re-run — the normal
# update path) are in $MY_NAMES and are not blockers: compose reconciles
# them. Whatever ELSE still holds one of these ports is not fass and is
# NEVER killed by this script — both ports can be moved. Probing is done
# by scripts/port_probe.py when python is present on the machine (a bind
# test proves the port is free); without python (see $PYBIN, detected
# above) no probing happens and the install continues (a taken port then
# surfaces at `up`).
# First holder of the port that is not a container of this install
# ($MY_NAMES) — our own stack is not a blocker.
port_docker_owner() {
  local n
  for n in $(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null); do
    case " ${MY_NAMES[*]:-} " in
      *" $n "*) continue ;;
      *) echo "$n"; return 0 ;;
    esac
  done
}
# True when a RUNNING container of this install publishes the port — an
# in-place re-run (the normal update path). Compose reconciles those
# containers, so they are not blockers either.
port_held_by_mine() {
  local n
  for n in $(docker ps --filter "publish=$1" --format '{{.Names}}' 2>/dev/null); do
    case " ${MY_NAMES[*]:-} " in
      *" $n "*) return 0 ;;
    esac
  done
  return 1
}

if [[ -n "$PYBIN" ]]; then
for P in "$UI_PORT" "$HTTP_PORT"; do
  "$PYBIN" "$REPO/scripts/port_probe.py" "$P" >/dev/null && continue
  owner="$(port_docker_owner "$P")"
  if [[ -n "$owner" ]]; then
    echo "error: port $P is held by the container '$owner' — it is not part of a fass install." >&2
    echo "Stop it (docker stop $owner) and re-run setup.sh." >&2
    exit 1
  fi
  if port_held_by_mine "$P"; then
    echo "note: port $P is held by this install's own running stack — compose will reconcile it."
    continue
  fi
  if [[ "$P" == "$UI_PORT" ]]; then
    echo "error: port $UI_PORT (the fass web UI) is in use by another program — stop it and re-run setup.sh (or pick another port with --ui-port)." >&2
    exit 1
  fi
  if [[ -t 0 ]] && (( ASSUME == 0 )); then
    while :; do
      printf "port $P (the http stream sidecar) is in use by another program — new port [$((P + 1))]: "
      read -r np || { echo "quitting." >&2; exit 1; }
      np="${np:-$((P + 1))}"
      [[ "$np" =~ ^[0-9]+$ ]] || { echo "  that is not a number"; continue; }
      [[ "$np" == "$UI_PORT" ]] && { echo "  that is the web UI port"; continue; }
      if ! "$PYBIN" "$REPO/scripts/port_probe.py" "$np" >/dev/null; then echo "  $np is taken too"; continue; fi
      HTTP_PORT="$np"
      break
    done
  else
    echo "error: port $P (the http stream sidecar) is in use by another program." >&2
    echo "Re-run with --http-port <a free port>." >&2
    exit 1
  fi
done
fi

# host:port from the URL (scheme/path stripped, missing port = 8080)
if (( LLM_SET )); then
  LLM_HOST="$(printf '%s' "$LLM_URL" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*||' -e 's|:.*||')"
  LLM_PORT="$(printf '%s' "$LLM_URL" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*||')"
  case "$LLM_PORT" in *:*) LLM_PORT="${LLM_PORT#*:}";; *) LLM_PORT=8080;; esac
  [[ "$LLM_HOST" == /* ]] && { echo "LLM URL has no host: $LLM_URL" >&2; exit 2; }
  # probe the connection once all LLM values are in (python-gated,
  # non-fatal: the LLM may come up later — the Config tab is the fix)
  if [[ -n "$PYBIN" ]]; then
    if "$PYBIN" "$REPO/scripts/port_probe.py" --connect "$LLM_HOST" "$LLM_PORT" >/dev/null; then
      echo "llm probe: $LLM_HOST:$LLM_PORT is reachable"
    else
      echo "warning: the LLM at $LLM_HOST:$LLM_PORT is not reachable right now — the install continues; check it later in the Config tab." >&2
    fi
  fi
else
  LLM_HOST=""; LLM_PORT=""
fi

echo "input  -> $INPUT"
echo "output -> $OUTPUT"
echo "log    -> $LOG"
echo "config -> $CONFIG"
echo "ports  -> web UI $UI_PORT | http stream $HTTP_PORT"
if (( LLM_SET )); then
  echo "llm    -> http://$LLM_HOST:$LLM_PORT model=$LLM_MODEL (${LLM_TIMEOUT}s timeout)$([[ -n "$API_KEY" ]] && echo ' (API key set)' || echo ' (no API key)')"
else
  if [[ -z "$PYBIN" && -f "$CFGJSON" ]]; then
    echo "llm    -> unchanged (no python on this machine — config.json could not be read or seeded; check the LLM section in the Config tab)"
  elif (( CFG_LLM_SET )); then
    echo "llm    -> unchanged (setup was told not to configure an LLM — the existing llm section in config.json is kept; the Config tab owns it)"
  else
    echo "llm    -> not configured (set it later in the Config tab)"
  fi
fi
if [[ -z "$PYBIN" && -f "$CFGJSON" ]]; then
  echo "db     -> unchanged (no python on this machine — config.json could not be read or seeded; check the database section in the Config tab)"
elif (( DB_IS_DEFAULT )); then
  echo "db     -> default (the fass-db pgvector container from this compose file)"
else
  echo "db     -> $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
fi
# The interactive ask runs AFTER the first gpu_check above — re-check and
# recompute GPU_CVD from the FINAL pin before the summary, docker/.env and
# the device overlay consume it.
gpu_check
echo "gpu    -> $([[ $GPU -eq 1 ]] && echo present || echo 'NOT FOUND (CPU-only: GPU commands generate, execution refused)')"
mkdir -p "$INPUT" "$OUTPUT" "$LOG" "$CONFIG" "$OUTPUT/http"

# compose reads .env from the project dir (docker/) at every `up`
cat > "$DIR/.env" <<EOF
FASS_INPUT_DIR=$INPUT
FASS_OUTPUT_DIR=$OUTPUT
FASS_LOG_DIR=$LOG
FASS_CONFIG_DIR=$CONFIG
FASS_GPU=$GPU
FASS_GPU_PIN=$GPU_PIN
FASS_GPU_CVD=$GPU_CVD
FASS_UI_PORT=$UI_PORT
FASS_HTTP_PORT=$HTTP_PORT
FASS_BIND=$BIND
EOF
echo "wrote $DIR/.env"

# The machine-local device exposure (docker/compose.local.yaml;
# scripts/web.sh adds it to every compose command when present).
# docker/compose.yaml itself carries NO reservation because docker
# compose (v5.5) merges `devices` lists ADDITIVELY across files and an
# overlay cannot remove or replace an entry — so the overlay is the SOLE
# source of the reservation:
#   no GPU            -> NO file: nothing asks for the nvidia runtime,
#                        `up` works on a CPU-only machine
#   GPU, pin 0        -> device_ids ["0"]
#   GPU, pin N > 0    -> device_ids ["0", "N"]: expose the pinned card
#                        together with index 0 (a container whose ONLY
#                        exposed device sits at a non-zero index breaks
#                        NVENC — see compose.yaml)
if [[ $GPU -eq 1 ]]; then
  if (( GPU_PIN > 0 )); then
    cat > "$DIR/compose.local.yaml" <<EOF
# written by setup.sh — the pinned GPU $GPU_PIN sits at a
# non-zero host index: expose it together with index 0 (NVENC requires
# an exposed index 0 — see the comment in compose.yaml)
services:
  fass:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              capabilities: [gpu]
              device_ids: ["0", "$GPU_PIN"]
EOF
    echo "wrote $DIR/compose.local.yaml (pin $GPU_PIN: exposing GPUs 0 + $GPU_PIN; ffmpeg on in-container index 1)"
  else
    cat > "$DIR/compose.local.yaml" <<EOF
# written by setup.sh — GPU present, fass pinned to index 0
services:
  fass:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              capabilities: [gpu]
              device_ids: ["0"]
EOF
    echo "wrote $DIR/compose.local.yaml (pin 0: exposing GPU 0)"
  fi
else
  rm -f "$DIR/compose.local.yaml"
  echo "no GPU: removed compose.local.yaml if present (no device reservation)"
fi

# the host address for the stream base URL: the machine's first LAN IP
# when detectable, localhost otherwise (the sidecar serves on all
# interfaces — the URL just tells a browser where to look)
HTTP_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ "$HTTP_HOST" =~ ^[0-9.]+$ ]] || HTTP_HOST="localhost"

# config.json: seed the deployment defaults (same shape as the container
# entrypoint seeds on first boot) with the answers filled; on an existing
# file keep everything and update llm (host/port/model/timeout, api_key
# only when one is given), the database (always the answers — a re-run
# accepts the saved values, so it is a no-op on an untouched install),
# the volumes and the stream base URL — but never gpu.enabled (user
# state; see the write below). A "no LLM" answer leaves an existing llm
# section untouched (the Config tab owns it).
if [[ -n "$PYBIN" ]]; then
"$PYBIN" - "$CFGJSON" "$INPUT" "$OUTPUT" "$LOG" "$LLM_HOST" "$LLM_PORT" "$API_KEY" "$GPU" "$LLM_TIMEOUT" "$HTTP_HOST" "$HTTP_PORT" "$LLM_MODEL" "$LLM_SET" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME" <<'PYEOF'
import json, os, sys
path, inp, outp, logp, host, port, key, gpu, timeout, http_host, http_port, model, llm_set = sys.argv[1:14]
db_host, db_port, db_user, db_pass, db_name = sys.argv[14:19]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
if llm_set == "1":
    llm_seed = {"provider": "openai", "host": host, "port": int(port),
                "api_key": key, "model": model, "timeout": int(timeout)}
else:
    # a fresh "no LLM" install writes the app's native unconfigured
    # shape (empty host + null port — the LLM adapter treats that as
    # disabled; the Config tab fills it later)
    llm_seed = {"provider": "openai", "host": "", "port": None,
                "api_key": "", "model": "", "timeout": int(timeout)}
seed = {
    "llm": llm_seed,
    "gpu": {"enabled": gpu == "1", "device": "all"},
    "streaming": {"enabled": True, "host_address": "172.17.0.1",
                  "port_mappings": [],
                  "http_base_url": f"http://{http_host}:{http_port}"},
    # the Files-tab 'hls play' video bitrate (the pydantic default is the
    # same value — this seed only documents it in the file). setdefault
    # means an upgrade NEVER overrides a user-tuned value (unlike
    # http_base_url, which is machine-specific and re-seeded below).
    "hls": {"video_bitrate_kbps": 3000},
    # a fresh deployment replaces an existing output file (-y) instead of
    # leaving ffmpeg to refuse the overwrite — the common first-install
    # workflow; the Config tab's "output file already exists" option can
    # turn it off. Existing configs keep whatever they already have.
    "volumes": {"overwrite": True},
}
for k, v in seed.items():
    cfg.setdefault(k, v)
if llm_set == "1":
    cfg["llm"].update({"host": host, "port": int(port), "model": model,
                       "timeout": int(timeout)})
    if key:
        cfg["llm"]["api_key"] = key
# llm_set == 0: the llm section is untouched — an existing config keeps
# whatever the user set there (the Config tab owns it); a fresh install
# keeps the seeded unconfigured shape
# gpu.enabled is USER state (the Config tab's GPU toggle) — a re-run must
# not clobber a CPU-only choice on a GPU host. Fresh installs get the
# machine-derived value (already seeded above); existing configs keep
# whatever the user set.
if cfg.get("gpu", {}).get("enabled") is None:
    cfg["gpu"]["enabled"] = gpu == "1"
cfg.setdefault("streaming", {})["http_base_url"] = f"http://{http_host}:{http_port}"
vols = cfg.setdefault("volumes", {})
vols.update({"input": inp, "output": outp, "log": logp})
db = cfg.setdefault("db", {})
db.update({"host": db_host, "port": int(db_port), "user_name": db_user,
           "password": db_pass, "database": db_name})
tmp = path + ".new"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
try:
    os.replace(tmp, path)
    print(f"updated {path}")
except PermissionError:
    print(f"cannot replace {path} (owned by root?) — run:\n"
          f"  sudo cp {tmp} {path} && rm {tmp}", file=sys.stderr)
    sys.exit(1)
PYEOF
else
  if (( LLM_SET )); then
    echo "warning: python is not on this machine — the LLM values you gave cannot be saved to $CFGJSON yet. Install python and re-run setup.sh, or set them in the Config tab after first boot." >&2
  elif [[ -f "$CFGJSON" ]]; then
    echo "note: python is not on this machine — $CFGJSON was not read or changed; the Config tab owns it"
  else
    echo "note: python is not on this machine — $CFGJSON will be seeded by the container entrypoint on first boot (the Config tab fills it later)"
  fi
fi

echo "pulling $IMAGE (large — the first install takes a while)"
docker pull "$IMAGE"
echo "pulling $RAG_IMAGE (RAG sidecar)"
docker pull "$RAG_IMAGE"

COMPOSE=(docker compose -f "$DIR/compose.yaml")
[[ -f "$DIR/compose.local.yaml" ]] && COMPOSE+=(-f "$DIR/compose.local.yaml")

# Database first: bring up fass-db on its own and create it OFFLINE via
# scripts/create-db.sh BEFORE the app comes up (pulls
# pgvector/pgvector:pg16 if needed, starts the container if missing,
# creates role + db, applies the full fass schema + major-version
# stamp — all idempotent, a no-op on an existing install). Soft-fail:
# if this fails, fass initialises the database itself on first connect
# (pre-existing behavior), so the install converges either way. A CUSTOM
# database skips all of it — the local fass-db would be dead weight: the
# external server is the user's, and fass applies the schema to it on
# first connect.
if (( DB_IS_DEFAULT )); then
  "${COMPOSE[@]}" up -d fass-db
  if ! bash "$DIR/../scripts/create-db.sh"; then
    echo "WARNING: offline database creation failed — fass will initialise the database itself on first connect (pre-existing behavior). Check: docker logs fass-db" >&2
  fi
  "${COMPOSE[@]}" up -d
else
  echo "database -> custom ($DB_USER@$DB_HOST:$DB_PORT/$DB_NAME) — the local fass-db service is NOT started; that database must exist, fass applies the schema on first connect"
  # the generic compose file still defines fass-db, so start the stack
  # WITHOUT it: the service list comes from the compose file itself
  # (a hard fallback covers a compose that cannot list its services)
  SVCS="$({ "${COMPOSE[@]}" config --services || true; } 2>/dev/null \
    | { grep -vx 'fass-db' || true; })"
  [[ -n "$SVCS" ]] || SVCS="fass fass-worker fass-rag fass-http"
  # shellcheck disable=SC2086
  "${COMPOSE[@]}" up -d $SVCS
fi
for i in $(seq 1 90); do
  if curl -sf -m 3 "http://127.0.0.1:$UI_PORT/healthz" >/dev/null 2>&1; then
    echo "web ui is served on: 'http://127.0.0.1:$UI_PORT'"
    if [[ "$BIND" == "0.0.0.0" ]]; then
      echo "fass is served on 0.0.0.0 (reachable from the network) — it is better to set the API key in the Config tab (API/MCP section) after the install is done, so the /v1/* API is not open to everyone on your network"
      echo "open these ports in your firewall (TCP): $UI_PORT (the fass web UI) and $HTTP_PORT (the http player — the HLS/DASH streams)"
    fi
    if (( GPU == 1 )); then
      CARD="$(printf '%s\n' "$GPU_LIST" | grep "^GPU $GPU_PIN:" | head -1 | sed 's/^GPU [0-9]*: //')"
      echo "gpu    -> fass encodes on GPU $GPU_PIN ($CARD) — to use another card, change FASS_GPU_PIN in docker/.env (e.g. FASS_GPU_PIN=1) and run './scripts/web.sh restart'"
    else
      echo "gpu    -> no NVIDIA GPU was detected — fass runs CPU-only (GPU commands are generated but refused at execution)"
    fi
    echo "use './scripts/web.sh start|pull|restart|stop|status|logs' if you don't install fass as service"
    exit 0
  fi
  sleep 1
done
echo "not healthy after 90 s — last logs:" >&2
docker logs --tail 30 fass >&2 || true
exit 1
