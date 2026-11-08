# fass — Docker deployment

The published image **`boris271142/fass`** (Docker Hub): fass compiled
with Cython, packaged together with FFmpeg 9.0 + NVIDIA hardware
acceleration (base `jrottenberg/ffmpeg:9.0-nvidia2404`). The stack is
three containers — `fass` (web UI + API, GPU), `fass-worker` (the Apply
sidecar, same image), and `fass-http` (the Apache sidecar serving the
http-destined HLS/DASH runs). The web UI gets a **Config tab** that
defines the whole deployment: host-folder mappings for `/input`,
`/output`, `/log`, stream port mappings, GPU, and the LLM provider. The
container can **execute** the generated FFmpeg commands (gated and
validated — see [Execution](#execution)).

```
host folder ──(volume)──▶ /input    source media
host folder ──(volume)──▶ /output   run results (playable from the UI)
host folder ──(volume)──▶ /log      run logs + run records
host folder ──(volume)──▶ /config   config.json (the Config tab reads/writes it)
```

## Host requirements

- Docker (with the `nvidia` runtime: NVIDIA driver + `nvidia-container-toolkit`)
- an NVIDIA GPU (for GPU encoding; the image is `nvidia2404`-flavoured anyway)

The image is a **deployment** build: `FASS_ALLOW_EXECUTE=1` is baked in, so
only run it where you want fass to execute FFmpeg. (The compiled CLI wheel
in `../wheel/`, run on its own, never executes anything — the gate is
environment-based, see [Execution](#execution).)

## Install (host folders are the only install-time question)

From the repo root:

```sh
./setup.sh            # asks for the input/output/log/config folders,
                      # the LLM endpoint (+ API key, timeout), the http
                      # stream port, and the GPU pin
./setup.sh --yes      # defaults: <repo>/media/{input,output,log},
                      # <repo>/docker-data/config
```

The script creates the folders, records them in **`docker/.env`** (compose
interpolates `${FASS_INPUT_DIR}` etc.; defaults are repo-relative) and in
the **`config.json` volumes section** (the Config tab's store), pulls
`boris271142/fass`, and starts the stack. It also writes `FASS_HTTP_PORT`
(the fass-http sidecar's host port, default `8080` — see
[HTTP streams](#http-streams)) and creates `<output>/http`.
The LLM model is NOT asked — set it in the Config tab.

After install the **Config tab owns the paths**: Apply re-creates the
container from `config.json`, and `scripts/web.sh` re-syncs `docker/.env`
from `config.json` before every compose up — so paths changed in the UI
survive restarts. `docker/.env` is machine-local (git-ignored); the compose
file stays generic. Manual route (what setup.sh does, by hand):

```sh
mkdir -p media/{input,output,log} docker-data/config
docker pull boris271142/fass
docker compose -f docker/compose.yaml up -d   # paths from docker/.env
```

### Stack control

`scripts/web.sh` wraps the compose lifecycle and opens the web GUI:

- `./scripts/web.sh start` — no-op if the stack is already healthy, else
  `up -d` + wait for healthz, then fires Chrome at `http://127.0.0.1:8000`
  (override with `FASS_GUI_URL` / `FASS_BROWSER`); over ssh (no graphical
  session — neither `DISPLAY` nor `WAYLAND_DISPLAY` set) it prints the URL
  instead.
- `./scripts/web.sh pull` — `docker pull` the latest published image and
  restart the stack on it. This is the upgrade path.
- `./scripts/web.sh restart` — recreate the containers from the current
  `.env` / config.
- `./scripts/web.sh stop` — `compose stop`; volumes and state are kept.
- `./scripts/web.sh status` — containers + healthz.
- `./scripts/web.sh logs [N]` — the last N lines of fass (default 100).

The entrypoint seeds `/config/config.json` on first start with deployment
sensible defaults (an OpenAI-compatible LLM at the docker bridge gateway
`172.17.0.1:8080` — the host, seen from the container; GPU enabled;
streaming enabled; empty volume mappings). Tune everything from the Config
tab afterwards.

## The Config tab

`GET/PUT /v1/config` behind the UI. Four sections:

The bottom of the tab prints the deployment's identity: the container's
ffmpeg build line (first line of `ffmpeg -version`, lib* versions
stripped) above the fass version string.

### Volumes

Host folders for `/input`, `/output`, `/log`. This is documentation + the
input to the **compose preview** shown under the tab — fass cannot remount
volumes in a running container, so changing them here means: update the
compose file, then **Apply** (or `docker compose up -d` again).

The runtime already resolves bare filenames for you: a command generated for
`clip.mp4` runs against `/input/clip.mp4` and writes to `/output/…`
automatically (the UI paths stay simple).

### Streaming

- **enabled** — the stream host placeholder `host` in generated commands is
  rewritten: *pull/push* addresses become `host_address` (the docker host as
  seen from the container, default bridge gateway `172.17.0.1`), and
  *udp/rtp listen* inputs (camera-in) bind to `0.0.0.0` so packets arriving
  on the mapped port reach the container.
- **host address** — override `172.17.0.1` (e.g. a custom bridge subnet).
- **port mappings** — one row per stream port: name, container port, host
  port, proto (tcp/udp). These must be mirrored in the compose file's
  `ports:` list (see the commented examples in `docker/compose.yaml`); the
  compose preview under the tab shows the exact lines to paste.
- **http base URL** — the base of the fass-http sidecar's stream URLs
  (`http://<host>:<port>`, seeded by setup.sh from the host address and
  `FASS_HTTP_PORT`). `GET /v1/streams` builds each playlist's URL as
  `<base>/http/<path>`. Changing the URL is config-only (reloaded per
  request); changing the port itself means editing `docker/.env` + a
  compose up.

**Receiving a stream** (camera → fass): map e.g. `5000:5000/udp`; the camera
pushes to `<host-ip>:5000`; the instruction can say "from the stream on
`udp://host:5000`" and fass binds `udp://0.0.0.0:5000` inside the container.

**Sending a stream** (fass → elsewhere): map e.g. `9000:9000/tcp` (srt) or
`1935:1935/tcp` (rtmp); "stream it to `srt://host:9000/stream`" becomes
`srt://172.17.0.1:9000/stream` inside the container — but an *external*
client reaches it on `<host-ip>:9000`.

### GPU

- **enabled** — the deployment exposes an NVIDIA GPU (compose reserves the
  `nvidia` devices; for a partial list, set `device` to indices like `0,1`).
- When on, asking for the GPU in an instruction ("use the gpu", "nvenc",
  "on the nvidia card") selects `h264_nvenc` / `hevc_nvenc` for H.264/H.265.
  VP9 stays CPU-only; x264 speed presets and the `baseline` profile are
  rejected for GPU (the planner says why). Quality maps to nvenc
  `-rc vbr -cq <crf>`; an explicit bitrate target switches to CBR-style
  `-b:v`.

### LLM

The NLU provider (the **llm** adapter; the deterministic **rules** adapter is
always available as fallback and needs nothing):

- **provider** `anthropic` — `api.anthropic.com`, needs an API key.
- **provider** `openai` — any OpenAI-compatible `/v1/chat/completions`
  endpoint (a local server — vLLM, llama.cpp, … — or a real end-user API):
  **scheme, host, port, api key, model id**. `scheme https` speaks TLS to
  real end-user APIs (OpenAI, DeepSeek, Groq, … — a blank port means 443);
  local servers stay `http`. From inside the container, a host-side server
  is reached through the bridge gateway: host `172.17.0.1`.
- **timeout** — the LLM connection timeout in seconds (default `10`,
  range `1..300`): a hung provider fails the generation with
  `LLM provider unreachable: timed out` instead of blocking it.
  `../setup.sh` asks for it (`--timeout`); the Config tab has the field.

  Thinking models are handled: if the model exhausts `max_tokens` in its
  reasoning trace (empty answer), fass retries once with 8× the token
  budget.

**Test LLM** button: sends a one-word probe through the real request path
(`POST /v1/config/llm-test`) and shows the reply + latency, using the values
in the form (no need to save first).

### Apply

Recreates the fass container from the saved config so volume/port/GPU
changes take effect, via the **fass-worker sidecar** (see Self-management
below): the UI's POST is forwarded to `fass-worker:8001/swap`, which stops
the old container, creates and starts the replacement, and records the
outcome in `last-apply.json` in the config volume. The UI expects the
connection to drop for a few seconds (two containers cannot publish the
same host port, so the old one must stop before the new one starts) and
polls `/healthz` + `/v1/config/apply-result` until the swap is recorded.
If the replacement cannot start, the old container is re-created from the
spec captured before the swap (best effort) and the state file says why.
Without the sidecar the button is disabled and the endpoint answers 409 —
the compose preview on the tab is then applied by hand
(`docker compose up -d`). LLM and stream-address changes need **no
restart** — the config is reloaded on every request.

## Execution

The Runs tab starts generated commands inside the container and shows status,
exit code, log tail, and the resulting file (playable/downloadable from
`/output`). The security model:

- **off unless `FASS_ALLOW_EXECUTE` is set** — the published image sets it;
  the compiled CLI, run on its own, never runs anything.
- **argv array only**, `shell=False` — a rendered shell string is never
  parsed; shell metacharacters are inert.
- **argv validated against the builder's flag vocabulary** before any process
  is spawned: every flag must be one the deterministic builder itself emits;
  codec/format/profile/pix-fmt/preset values must come from the registry;
  map/filter/number values are pattern-checked. Anything else is rejected.
- bare filenames resolve against the volumes (`/input`, `/output`); stream
  URLs and absolute paths pass through untouched.
- runs are process groups (`start_new_session`); **Stop** kills the exact
  group (SIGTERM → SIGKILL after 5 s). Records + logs persist in `/log/runs`
  across restarts; a run left `running` by a crash is marked `interrupted`
  on next read.

## Self-management (optional)

The Config tab's **Apply** button recreates the fass container — and a
container **cannot recreate itself**: the process answering the request
runs inside the container being stopped, and nothing inside a container
survives its own stop (the engine SIGKILLs the graceful-shutdown deadlock
before the create step can run). So the swap is orchestrated by the
**fass-worker sidecar** — the same image with `command: ["worker",
"--port", "8001"]`, declared next to fass in `docker/compose.yaml`.

The compose file wires it: the docker socket mount on **both** services,
`FASS_DOCKER_MANAGE=1` on both, and `FASS_DOCKER_WORKER=fass-worker:8001`
on fass. Both then talk to the Docker Engine API directly (no docker CLI
in the image):

- fass forwards the UI's Apply to the worker's `POST /swap` and relays the
  ack; the worker performs the stop → delete → create → start in a
  background thread so the ack reaches the UI first;
- the worker writes the outcome to `last-apply.json` in the shared
  `/config` volume; the UI reads it via `GET /v1/config/apply-result`
  after fass is back;
- the replacement keeps the old container's network, env, labels, and any
  unmanaged mounts (the socket itself); the four managed volumes, port
  mappings, restart policy and GPU reservation come from the saved config.

The socket grant means each of these containers can manage *any* container
on the host — only run the stack where you accept that.

## RAG (not shipped in the public image)

The fass UI has a **RAG tab** — a direct query box for the retrieval
service that backs the **RAG evidence** on ready results. The public
image ships **without** a RAG sidecar, so in this deployment the service
status reads **unavailable**: ready results carry no RAG evidence and the
query box reports the service down. Generation is unaffected — the
fass-side RAG client is fail-open: a missing service degrades generation
to evidence-less, it never blocks it.

## Tee multi-output

`hls and dash at the same time` (also `both hls and dash`, `tee to hls
and dash`, either order) selects the **tee** muxer: ONE encode writing
both segmented outputs in a single command. The destination is FFmpeg's
bracket template —

```
-f tee [f=hls]stream.m3u8|[f=dash]stream.mpd
```

— each branch carries its muxer and options INSIDE the brackets
(colon-separated: `[f=hls:hls_list_size=10:hls_playlist_type=event]…`),
never as separate `-key value` flags. The live/window/segment phrasings
route into the hls branch, the `dash_*` options into the dash branch;
the tee muxer accepts what its branches accept (registry group union
`tee = hls + dash + tee`). A tee run is not http-served — the
destination is a template, not one playlist (see
[HTTP streams](#http-streams)).

## Quality metrics (VMAF / PSNR / SSIM)

The comparison convention: the **reference** is the source — the main
asset, a file in the input folder — and the **distorted** clip is the
transcoded file in the output folder. `compute vmaf score` with only
the main asset generates the command directly; the distorted clip is
auto-detected in the output folder (same basename as the main wins,
else the only video file, else the newest top-level video;
subdirectories like `http/` are not scanned). The command follows the
Netflix vmaf docs order — reference is input 0, distorted input 1, the
metric writes to the run log, nothing is written to a file:

```
ffmpeg -i titan.mp4 -i /output/titan.webm -filter_complex '…libvmaf…[cmp]' -map [cmp] -f null -
```

Explicit bindings override the auto-detection: bind a second video
asset (main = distorted, the asset = reference), or name the distorted
clip as the `distorted` asset (the web UI's Output field does this).
When the output folder holds no video, the clarification asks for the
distorted file.

## HTTP streams

HLS/DASH runs destined for browser playback are served by the
**fass-http** sidecar — a plain `httpd:2.4-alpine` static server that is
part of the default deployment: `docker compose -f docker/compose.yaml
up -d` brings it up together with fass.

- The **whole output volume** is mounted read-only at the sidecar's
  htdocs root, so a file at `{output}/http/<run-id>/stream.m3u8` is
  served at `http://<host>:<port>/http/<run-id>/stream.m3u8` — the URL
  maps 1:1 onto the file, nothing is rewritten.
- The sidecar's host port comes from `docker/.env`
  (`FASS_HTTP_PORT`, default `8080` — fass owns `8000`). `../setup.sh`
  asks for it, writes it to `.env`, and creates the `<output>/http/`
  folder.
- A run destined for http serving writes its playlist into a **per-run
  subdir** `{output}/http/<run-id>/`, and ffmpeg runs with that dir as
  its working directory so the segments land beside the playlist. The
  per-run dirs are the DASH/HLS segment-name collision fix: the muxers
  name their segments independent of the playlist file
  (`init-stream0.m4s`, `chunk-stream0-00001.m4s`, `segment0.ts`, …), so
  two runs sharing one directory clobber each other's segments. The
  Files tab's **hls play** departs from the per-run layout on purpose:
  each *source file* gets one permanent subdir `{output}/http/<name>/`
  with the playlist named after the source (`<name>.m3u8`) — re-playing
  the same file overwrites its own tree, different files never
  collide, and the Player tab shows the stream **live** while its
  encoding run is in flight.
- `GET /v1/streams` lists the playlists found under the output
  volume's `http/` subdir (`.m3u8` → kind `hls`, `.mpd` → kind `dash`),
  newest first, each with its full URL — built from the config's
  `streaming.http_base_url` (see the Config tab's Streaming section).
- The sidecar sends **`Access-Control-Allow-Origin: *`** on the stream
  files (playlists plus their `.ts`/`.m4s` segments) and **`Cache-Control:
  no-cache`** on the playlists, so the web-UI **Player** tab — a page served
  by fass on `8000`, i.e. a different origin — can play them cross-origin and
  never serves a stale copy of a growing live playlist. The rules are one
  small file, `docker/fass-http/httpd-fass.conf`, mounted read-only into the
  image's `conf/extra/` and pulled in by the service's `command:` (the stock
  `httpd.conf` includes no `conf/extra` glob).

**Who owns what:** the Config tab's **Apply** recreates the fass
container only (the fass-worker swap) — it cannot create or restart
fass-http, which is owned by the host-side `compose up`
(`../scripts/web.sh start|restart`). A first-time sidecar, or a changed
`FASS_HTTP_PORT`, takes effect on the next start. `scripts/web.sh`
re-syncs `docker/.env` from `config.json` before every up and preserves
every non-volume line, so `FASS_HTTP_PORT` (like `FASS_GPU`) survives.

## CLI wheel vs docker image

| | CLI wheel | docker image |
|---|---|---|
| execution | off (env gate) | on (`FASS_ALLOW_EXECUTE=1`) |
| config file | `./.fass-config.json` | `/config/config.json` (seeded) |
| volumes | cwd / local paths | `/input` `/output` `/log` mounts |
| FFmpeg | whatever is on PATH | 9.0 + nvenc, in the image |
| RAG | off (code default) | off (no sidecar shipped) |

Both run the same compiled code; the difference is environment, not code
paths.
