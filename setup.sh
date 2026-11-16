#!/usr/bin/env bash
# fass docker install — one-time setup of a machine (the host folders, the
# LLM endpoint, its API key and its connection timeout are the install-time
# questions; the model itself is tuned in the web GUI).
#
#   ./setup.sh                                  # interactive prompts
#   ./setup.sh --yes                            # accept the defaults
#   ./setup.sh --yes --input /srv/in --output /srv/out --log /srv/log
#   ./setup.sh --config /srv/config             # move the config folder
#   ./setup.sh --yes --llm http://192.168.0.9:8080 --api-key sk-...
#   ./setup.sh --yes --llm http://192.168.0.9:8080 --timeout 30
#   ./setup.sh --yes --http-port 9090           # the http stream sidecar port
#   ./setup.sh --yes --gpu-pin 1                # fass's ffmpeg on GPU 1
#   ./setup.sh --upgrade                        # an older fass install is on
#                                               # the machine: remove its
#                                               # containers instead of asking
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
# (/config), asks for the LLM base URL (OpenAI-compatible endpoint), the
# API key (empty = not required), the LLM connection timeout in seconds
# (default 10, 1..300) and the http stream port (the fass-http sidecar
# serving HLS/DASH runs), then pulls the image and starts the stack. The
# model name is NOT asked — set it in the Config tab afterwards.
#
# GPU: probes nvidia-smi. Without a GPU the deployment is CPU-only:
# no device reservation is written at all and the container gets
# FASS_GPU_PROBE=0, so GPU-involved ffmpeg commands are GENERATED
# (argv/CLI) but REFUSED at execution (start_run raises 403) — see the
# Execution section of docker/README.md. On a multi-GPU machine,
# --gpu-pin N (default 0, = the single-GPU-host answer) picks the card
# fass's ffmpeg encodes on; a non-zero pin also exposes index 0 to the
# container (a required NVENC workaround — see compose.yaml).
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

# At least 2 GB of available RAM — the stack (ffmpeg, the sidecars, the LLM
# adapter) OOMs or thraps badly below that. MemAvailable counts reclaimable
# page cache, so memory that is used but reclaimable still counts as free.
FREE_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
[[ "$FREE_MB" =~ ^[0-9]+$ ]] \
  || { echo "error: could not read available memory from /proc/meminfo — cannot continue." >&2; exit 1; }
(( FREE_MB >= 2048 )) \
  || { echo "error: only ${FREE_MB} MB of RAM available — fass needs at least 2048 MB free." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/docker" && pwd)"
REPO="$(dirname "$DIR")"
IMAGE="boris271142/fass:latest"
RAG_IMAGE="boris271142/fass-rag:latest"

INPUT="${FASS_INPUT_DIR:-$REPO/media/input}"
OUTPUT="${FASS_OUTPUT_DIR:-$REPO/media/output}"
LOG="${FASS_LOG_DIR:-$REPO/media/log}"
CONFIG="${FASS_CONFIG_DIR:-$REPO/docker-data/config}"
LLM_URL=""
API_KEY=""
LLM_TIMEOUT="10"
TIMEOUT_SET=0
HTTP_PORT=8080
GPU_PIN="${FASS_GPU_PIN:-0}"
ASSUME=0
UPGRADE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)  INPUT="$2";  shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --log)    LOG="$2";    shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --llm)    LLM_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --timeout) LLM_TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --gpu-pin)  GPU_PIN="$2"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    -y|--yes) ASSUME=1; shift ;;
    -h|--help) sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# absolute paths, no need to exist yet (Docker requires absolute binds)
canon() { realpath -m -- "$1"; }
INPUT="$(canon "$INPUT")"; OUTPUT="$(canon "$OUTPUT")"
LOG="$(canon "$LOG")";     CONFIG="$(canon "$CONFIG")"

# GPU probe: nvidia-smi listing GPUs (host driver + toolkit present)
GPU=1
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
  GPU=0
fi

# Which GPU fass's ffmpeg uses (host index, nvidia-smi -L order).
# Default 0 — correct on single-GPU hosts. The pin is recorded in
# docker/.env (FASS_GPU_PIN); a non-zero pin N additionally needs index 0
# exposed to the container (a container whose ONLY exposed device sits at
# a non-zero index breaks NVENC — see the device comment in
# docker/compose.yaml), which the local overlay below arranges.
# CUDA_VISIBLE_DEVICES is the IN-CONTAINER index, and devices keep their
# position in the exposure list (verified 2026-11-06: exposure ["0","2"]
# presents the host's GPU 2 as in-container GPU 1, and CVD=2 fails there):
# ["0"] -> the pinned card is in-container 0, ["0","N"] -> it is 1.
if [[ $GPU -eq 1 ]]; then
  [[ "$GPU_PIN" =~ ^[0-9]+$ ]] && (( GPU_PIN <= 63 )) \
    || { echo "gpu pin must be a whole index between 0 and 63 (got: $GPU_PIN)" >&2; exit 2; }
  nvidia-smi -L | grep -q "^GPU $GPU_PIN:" \
    || { echo "no GPU at index $GPU_PIN (nvidia-smi -L lists the available ones)" >&2; exit 2; }
  if (( GPU_PIN > 0 )); then GPU_CVD=1; else GPU_CVD=0; fi
else
  GPU_CVD=0
fi

# --- existing fass install (upgrade detection) ------------------------------
# The stack uses FIXED container names (the compose container_name values):
# fass, fass-worker, fass-rag, fass-http — plus the project-prefixed
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
    fass|fass-worker|fass-rag|fass-http|docker-fass-rag-1|docker-fass-worker-1|docker-fass-http-1) ;;
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
# defaults for the prompts: existing config wins, else the deployment
# defaults the container entrypoint seeds (an OpenAI-compatible LLM on the
# docker bridge gateway — 172.17.0.1 is the host, seen from the container)
LLM_HOST="172.17.0.1"; LLM_PORT="8080"; CFG_API_KEY=""; CFG_GPU="true"; CFG_TIMEOUT="10"; CFG_HTTP_PORT="8080"
if [[ -f "$CFGJSON" ]]; then
  # api_key LAST: it may be empty (or contain spaces) — a positional read
  # must not shift the fields before it
  read -r LLM_HOST LLM_PORT CFG_GPU CFG_TIMEOUT CFG_HTTP_PORT CFG_API_KEY < <(python3 - "$CFGJSON" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
llm = cfg.get("llm") or {}
base = (cfg.get("streaming") or {}).get("http_base_url") or ""
port = 8080
if "://" in base:
    hostpart = base.split("://", 1)[1].rsplit("/", 1)[0]
    if ":" in hostpart:
        try:
            port = int(hostpart.rsplit(":", 1)[1])
        except ValueError:
            pass
print(llm.get("host", "172.17.0.1"), llm.get("port", 8080),
      str(bool((cfg.get("gpu") or {}).get("enabled", True))).lower(),
      (llm.get("timeout") or 10), port, llm.get("api_key", ""))
PYEOF
)
fi
[[ -n "$LLM_URL" ]] || LLM_URL="http://$LLM_HOST:$LLM_PORT"
# --timeout wins over the saved config; the saved config wins over 10
[[ $TIMEOUT_SET -eq 0 ]] && LLM_TIMEOUT="$CFG_TIMEOUT"

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
  LLM_URL="$(ask "LLM base URL (OpenAI-compatible)" "$LLM_URL")"
  API_KEY="$(ask "LLM API key (empty = not required)" "$CFG_API_KEY")"
  LLM_TIMEOUT="$(ask "LLM connection timeout seconds" "$LLM_TIMEOUT")"
  HTTP_PORT="$(ask "http stream port (HLS/DASH sidecar)" "$CFG_HTTP_PORT")"
fi
# the timeout is a config number (1..300 s), not free text
[[ "$LLM_TIMEOUT" =~ ^[0-9]+$ ]] && (( LLM_TIMEOUT >= 1 && LLM_TIMEOUT <= 300 )) \
  || { echo "LLM timeout must be a whole number of seconds between 1 and 300 (got: $LLM_TIMEOUT)" >&2; exit 2; }
for p in "$INPUT" "$OUTPUT" "$LOG" "$CONFIG"; do
  [[ "$p" == /* ]] || { echo "not an absolute path: $p" >&2; exit 2; }
done
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [[ "$HTTP_PORT" -ge 1 && "$HTTP_PORT" -le 65535 ]] \
  || { echo "http stream port must be a number 1-65535: $HTTP_PORT" >&2; exit 2; }

# --- port availability -------------------------------------------------------
# The stack publishes the web UI on 8000 and the fass-http sidecar on
# $HTTP_PORT (fass-rag stays internal). Old-install containers are gone by
# now; containers of THIS install dir (an in-place re-run — the normal
# update path) are in $MY_NAMES and are not blockers: compose reconciles
# them. Whatever ELSE still holds one of these ports is not fass and is
# NEVER killed by this script — the sidecar port can be moved, the UI port
# is fixed at 8000.
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}
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

for P in 8000 "$HTTP_PORT"; do
  port_in_use "$P" || continue
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
  if [[ "$P" == 8000 ]]; then
    echo "error: port 8000 (the fass web UI) is in use by another program — stop it and re-run setup.sh." >&2
    exit 1
  fi
  if [[ -t 0 ]] && (( ASSUME == 0 )); then
    while :; do
      printf "port $P (the http stream sidecar) is in use by another program — new port [$((P + 1))]: "
      read -r np || { echo "quitting." >&2; exit 1; }
      np="${np:-$((P + 1))}"
      [[ "$np" =~ ^[0-9]+$ ]] || { echo "  that is not a number"; continue; }
      if port_in_use "$np"; then echo "  $np is taken too"; continue; fi
      HTTP_PORT="$np"
      break
    done
  else
    echo "error: port $P (the http stream sidecar) is in use by another program." >&2
    echo "Re-run with --http-port <a free port>." >&2
    exit 1
  fi
done

# host:port from the URL (scheme/path stripped, missing port = 8080)
LLM_HOST="$(printf '%s' "$LLM_URL" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*||' -e 's|:.*||')"
LLM_PORT="$(printf '%s' "$LLM_URL" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*||')"
case "$LLM_PORT" in *:*) LLM_PORT="${LLM_PORT#*:}";; *) LLM_PORT=8080;; esac
[[ "$LLM_HOST" == /* ]] && { echo "LLM URL has no host: $LLM_URL" >&2; exit 2; }

echo "input  -> $INPUT"
echo "output -> $OUTPUT"
echo "log    -> $LOG"
echo "config -> $CONFIG"
echo "llm    -> http://$LLM_HOST:$LLM_PORT (${LLM_TIMEOUT}s timeout)$([[ -n "$API_KEY" ]] && echo ' (API key set)' || echo ' (no API key)')"
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
FASS_HTTP_PORT=$HTTP_PORT
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
# file keep everything and update llm, gpu.enabled, the volumes and the
# stream base URL
python3 - "$CFGJSON" "$INPUT" "$OUTPUT" "$LOG" "$LLM_HOST" "$LLM_PORT" "$API_KEY" "$GPU" "$LLM_TIMEOUT" "$HTTP_HOST" "$HTTP_PORT" <<'PYEOF'
import json, os, sys
path, inp, outp, logp, host, port, key, gpu, timeout, http_host, http_port = sys.argv[1:12]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
seed = {
    "llm": {"provider": "openai", "host": host, "port": int(port),
            "api_key": key, "model": "qwen3.8-27b", "timeout": int(timeout)},
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
cfg["llm"].update({"host": host, "port": int(port), "timeout": int(timeout)})
if key:
    cfg["llm"]["api_key"] = key
cfg["gpu"]["enabled"] = gpu == "1"
cfg.setdefault("streaming", {})["http_base_url"] = f"http://{http_host}:{http_port}"
vols = cfg.setdefault("volumes", {})
vols.update({"input": inp, "output": outp, "log": logp})
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

echo "pulling $IMAGE (large — the first install takes a while)"
docker pull "$IMAGE"
echo "pulling $RAG_IMAGE (RAG sidecar)"
docker pull "$RAG_IMAGE"

COMPOSE=(docker compose -f "$DIR/compose.yaml")
[[ -f "$DIR/compose.local.yaml" ]] && COMPOSE+=(-f "$DIR/compose.local.yaml")
"${COMPOSE[@]}" up -d
for i in $(seq 1 90); do
  if curl -sf -m 3 "http://127.0.0.1:8000/healthz" >/dev/null 2>&1; then
    echo "healthy — open http://127.0.0.1:8000 (Config tab: model, GPU, ports)"
    echo "start / pull / restart / stop / status / logs: ./scripts/web.sh"
    exit 0
  fi
  sleep 1
done
echo "not healthy after 90 s — last logs:" >&2
docker logs --tail 30 fass >&2 || true
exit 1
