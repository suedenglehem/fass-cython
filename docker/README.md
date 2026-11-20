# fass — Docker deployment

The published image **`boris271142/fass`** (Docker Hub): fass packaged
together with FFmpeg 9.0 + NVIDIA hardware acceleration (base
`boris271142/ffmpeg-sm_75_120:latest`), plus the **`boris271142/fass-rag`**
retrieval image. The stack is four containers — `fass` (web UI + API,
GPU), `fass-worker` (the Apply sidecar, same image), `fass-rag` (the
lexical RAG retriever, see [RAG](#rag-default-service-m13)), and
`fass-http` (the Apache sidecar serving the http-destined HLS/DASH
runs). The web UI gets a **Config tab** that defines the whole
deployment: host-folder mappings for `/input`, `/output`, `/log`,
`/scores`, stream port mappings, GPU, and the LLM provider. The container can
**execute** the generated FFmpeg commands (gated and validated — see
[Execution](#execution)).

```
host folder ──(volume)──▶ /input    source media
host folder ──(volume)──▶ /output   run results (playable from the UI)
host folder ──(volume)──▶ /log      run logs + run records
host folder ──(volume)──▶ /scores   VMAF score files (UUID.json + master.txt)
host folder ──(volume)──▶ /config   config.json (the Config tab reads/writes it)
```

## Host requirements

- Docker (with the `nvidia` runtime: NVIDIA driver + `nvidia-container-toolkit`)
- an NVIDIA GPU (for GPU encoding)
- the base image `boris271142/ffmpeg-sm_75_120:latest` (FFmpeg 9.0.2
  rebuilt with CUDA sm_75…sm_120, libvmaf with CUDA, and RIST — pulled
  automatically on first build; the main README's
  [Docker deployment](../README.md#docker-deployment) section covers the
  supported card generations)

The image is a **deployment** build: `FASS_ALLOW_EXECUTE=1` is baked in, so
only run it where you want fass to execute FFmpeg. A development checkout
(`python -m fass serve` from the repo) never executes anything — the gate is
environment-based, see [Execution](#execution).

## Install (folders, ports, and an optional LLM are the install-time questions)

The compose file is generic: the host folders come from **`docker/.env`**
(compose interpolates `${FASS_INPUT_DIR}` etc.; defaults are
repo-relative), the host ports from the install-time answers
(`FASS_UI_PORT`, `FASS_HTTP_PORT`), the bind address from
`FASS_BIND`, and everything else — the LLM endpoint, the GPU — is a
`config.json` value the **Config tab** owns after first boot.

The published dist (fass-cython) ships **`setup.sh`** at the repo root:
it asks for the input/output/log/config folders, the **web UI port**
(default `8000`), the **http stream port** (the fass-http sidecar,
default `8001` — `8080` is often taken by local LLM servers — see
[HTTP streams](#http-streams-m136)), the **bind address** —
`127.0.0.1` (local only, the default) or `0.0.0.0` (all interfaces; on
`0.0.0.0` the final messages remind to set the API key in the Config
tab after the install is done, and say which ports to open in the
firewall — the web UI and the http player) — then **which GPU to use**
(asked only when several cards are found), **whether the database stays
the default** (the `fass-db` pgvector container from this compose file
— a custom answer asks the db host, port, user name, password and
database one by one, and the local `fass-db` service is then not
started), and **whether fass will use an LLM at all**; when yes, for
the LLM base URL (OpenAI-compatible endpoint), the API key (empty =
not required) and the **model name**; on a re-run the existing
install's ports, bind address and database values are the prompt
defaults (nothing is silently reset); creates the folders; records them
in `docker/.env` and the **`config.json` volumes section**; writes
`FASS_UI_PORT` + `FASS_HTTP_PORT` + `FASS_BIND` and creates
`<output>/http`; with python on the machine, `scripts/port_probe.py`
checks both ports for availability and probes the LLM endpoint for
reachability (without python no probing happens); when the database is
the default, creates it **offline via `scripts/create-db.sh`** (see
[Database](#database-default-service)); then starts the stack. The LLM
connection timeout is NOT asked — the image default is `10` s, tuned in
the Config tab. Flags cover every question: `--yes --ui-port
--http-port --bind --no-llm --llm --api-key --model --gpu-pin`
(`--timeout` sets the non-asked LLM timeout, for non-interactive
installs). `--remove` stops and removes the whole fass
stack — every fass container, the stack network **and the app state in
`docker-data`** (the config and the database contents; the postgres
files are owned by the container-side postgres user, so `--remove`
removes them through a docker root-helper — that way an uninstall can
never leave a directory a plain user cannot delete). The media folders
and the pulled images survive, and a re-run of `setup.sh` installs
fresh (confirmed on a tty — the question names what is destroyed;
`--yes` skips the confirmation).

In a development checkout (no `setup.sh`) the same install by hand:

```sh
mkdir -p media/{input,output,log,scores} docker-data/config
docker compose -f docker/compose.yaml up -d   # paths from docker/.env;
                                              # first run builds fass:latest
```

Without `setup.sh` the compose defaults apply — web UI `8000`, http
stream `8001` — and the LLM is the entrypoint seed, set in the Config
tab.

After install the **Config tab owns the paths**: Apply re-creates the
container from `config.json`, and the launcher re-syncs `docker/.env`
from `config.json` before every compose up (`docker/launcher.sh` in a
development checkout, `scripts/web.sh` in the published dist) — so paths
changed in the UI survive rebuilds. `docker/.env` is machine-local
(git-ignored); the compose file stays generic.

### File ownership (no sudo)

Everything the containers write — output files, run logs, job records
(`/log/runs`), `config.json`, scores — is owned by **the user who ran
`setup.sh`**, not by root. The mechanism: `setup.sh` records your
`id -u`/`id -g` as **`FASS_UID`/`FASS_GID`** (and the host docker-group
gid as `FASS_DOCKER_GID`) in `docker/.env`; the compose file runs the
`fass` and `fass-worker` containers as that user (`user:` +
`group_add:`, so the docker socket for the Apply button stays usable).
Unset keys keep the legacy `0:0` (root). **No sudo is required
anywhere in the install, and never any user or group administration**
(no `useradd`, `groupadd`, `usermod`, no `/etc/group` edits): being
able to run `docker` (the standing docker prerequisite) is all the
privilege the ownership model needs — the root-side work, when it is
ever needed, is done by the docker daemon, not by your account.
`fass-http` stays root by design (it binds `:80` inside its container),
`fass-db` runs postgres' own user, `fass-rag` is non-root in-image.

Uninstall is therefore plain file removal: `setup.sh --remove` removes
the containers, the network and `docker-data` (config + the postgres
data — the uid-`999` database files included, deleted via the same
docker root-helper, so nothing root-owned is left behind), and then
`rm -rf` the remaining folders — nothing waits for sudo. Only if you
skip or answer `n` to `--remove` do the folders stay; postgres' own
data directory (`docker-data/db`, owned by uid `999` like every
postgres volume) can then be removed with
`docker run --rm -u 0:0 -v "$PWD/docker-data:/d" busybox:latest rm -rf /d/db`.

**Migrating an install made before this change** (root-owned leftovers
that a plain user cannot delete): re-run `./setup.sh --upgrade`. It
chowns `output`/`log`/`config`/`scores` to you; where plain `chown`
fails (this is exactly the no-sudo case) it falls back to a **docker
root helper container** — `docker run --rm -u 0:0 -v "<dir>":"<dir>"
busybox:latest chown -R UID:GID "<dir>"` per folder — which needs no
sudo because the docker daemon itself is root. Your **input folder (the
media library) is never chowned**. The same one-liners work by hand,
and `sudo ./setup.sh --upgrade` also works where sudo is available:
under sudo, setup adopts the sudo'ing user (`SUDO_UID`/`SUDO_GID`) and
chowns directly. Override order: `FASS_UID`/`FASS_GID`/`FASS_DOCKER_GID`
env vars > the values already in `docker/.env` > `SUDO_UID`/`SUDO_GID`
> `id -u`/`id -g`/the docker group.

### Launcher (start / stop + GUI)

`docker/launcher.sh` wraps the compose lifecycle and opens the web GUI:

- `./launcher.sh start` — no-op if the stack is already healthy, else
  `up -d` + wait for healthz, then fires Chrome at the web UI
  (`http://127.0.0.1:<FASS_UI_PORT>` from `docker/.env`, default `8000`;
  override with `FASS_GUI_URL` / `FASS_BROWSER`); over ssh (no graphical
  session — neither `DISPLAY` nor `WAYLAND_DISPLAY` set) it prints the URL
  instead.
- `./launcher.sh rebuild` — `up -d --build` (fresh image) + GUI.
- `./launcher.sh stop` — `compose stop`; volumes and state are kept.
- `./launcher.sh status` — containers + healthz.

The entrypoint seeds `/config/config.json` on first start with deployment
sensible defaults (OpenAI-compatible LLM at the docker bridge gateway
`172.17.0.1:8080`, model `qwen3.8-27b`, timeout `10` s — the strata
server on the host; GPU enabled; streaming enabled; empty volume
mappings). Tune everything from the Config tab afterwards.

> `docker/compose.yaml` hard-codes `docker-data/` under the repo path on this
> machine — edit the four volume paths to your host layout before deploying
> elsewhere. The Config tab's volume fields show the *intended* host folders
> and drive the generated compose preview; the actual mounts are whatever the
> compose file (or `docker run`) says.

### Start from an exported config (another host)

The Config tab's **Export conf.json** button (the same document the "Submit a
bug" report gathers) is the export side. To bring that configuration to
another machine, put the file there and run:

```
./docker/start-from-conf.sh /path/to/conf.json            # install config + up -d
./docker/start-from-conf.sh /path/to/conf.json --rebuild  # + up -d --build
./docker/start-from-conf.sh /path/to/conf.json --dry-run  # print the result, touch nothing
```

It accepts both document shapes — the `{config, environment}` export and the
raw `GET /v1/config` document. What is applied: the Config-tab sections
(volumes, streaming, GPU, RAG) — **excluding the LLM provider section**, which
is ignored on purpose: this host keeps its own LLM settings (a fresh host
gets the defaults until the LLM is set in the Config tab). A section present
in the file replaces; a section absent keeps the target's existing value.

Host-side install choices are not part of the config file: the GPU device
reservation in compose, the `FASS_GPU` probe flag, and the install-time host
folders — install-time host choices: the dist's `setup.sh` prompts,
else the compose defaults. Two
carried-over values to check in the Config tab after start if the hosts
differ: `streaming.http_base_url` (the fass-http address) and the
`volumes.*_remote` store addresses/credentials. If the stack is already up,
volume/GPU changes only take effect on a container recreation — use
`--rebuild` (or stop first).

## The Config tab

`GET/PUT /v1/config` behind the UI. The deployment-relevant sections
(the tab also carries Shaka player, RAG, API key and Appearance):

The bottom of the tab prints the deployment's identity: the container's
ffmpeg build line (first line of `ffmpeg -version`, lib* versions
stripped) above the fass version string.

### Volumes

Host folders for `/input`, `/output`, `/log`, `/scores`. This is
documentation + the
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
  (`http://<host>:<port>`, seeded by the dist's `setup.sh` from the host
  address and `FASS_HTTP_PORT`). `GET /v1/streams` builds each playlist's
  URL as
  `<base>/http/<path>`. Changing the URL is config-only (reloaded per
  request); changing the port itself means editing `docker/.env` + a
  compose up.

**Receiving a stream** (camera → fass): map e.g. `5000:5000/udp`; the camera
pushes to `<host-ip>:5000`; the instruction can say "from the stream on
`udp://host:5000`" and fass binds `udp://0.0.0.0:5000` inside the container.
RIST rides the same UDP-port mapping — `rist://@host:5000` (`@` = a
*listening* socket: fass is the receiver and must start FIRST, the camera
connects after); operational details (reader never self-terminates, the
sender's cosmetic teardown error) in the main README's [Docker
deployment — RIST input/output](../README.md#docker-deployment) section.

**Sending a stream** (fass → elsewhere): map e.g. `9000:9000/tcp` (srt) or
`1935:1935/tcp` (rtmp); "stream it to `srt://host:9000/stream`" becomes
`srt://172.17.0.1:9000/stream` inside the container — but an *external*
client reaches it on `<host-ip>:9000`. A `rist://host:9001` destination
behaves the same (the remote side's receiver runs first).

### GPU

- **enabled** — the deployment exposes an NVIDIA GPU (compose reserves the
  `nvidia` devices — which host cards are VISIBLE from the container is
  that install-time reservation, see `FASS_GPU_PIN` below).
- **device** — the *encode pin*: which visible card ffmpeg encodes on,
  written as `CUDA_VISIBLE_DEVICES` on the container by the next Apply
  (`"all"` = un-pinned, CUDA uses the first visible card). Indices are
  the container-visible ones — the Config tab lists them
  (`GET /v1/gpus`); an Apply pinning an index the container cannot see
  is refused (422). Editing this line by hand is the manual re-pick:
  the same knob the **encode on** dropdown drives.
- **install-time detection (setup.sh)** — setup.sh lists the cards with
  `nvidia-smi -L`, and when the nvidia-smi binary is absent the python
  `scripts/gpu_probe.py` reads `/proc/driver/nvidia/gpus` (the driver
  exposes one directory per card even without the toolkit). With several
  cards the interactive prompt offers them (default `0`); `--gpu-pin N`
  picks one non-interactively, and an out-of-range pin is refused with
  the detected cards listed. A non-zero pin exposes index 0 alongside it
  (the NVENC workaround — see compose.yaml). The final messages explain
  how to change the card later — for a different set of *visible* cards,
  `FASS_GPU_PIN` in `docker/.env` + `docker compose up -d` (host-side);
  to move *encoding* between the visible cards, no host edit is needed —
  the Config tab's **encode on** dropdown + Save + Apply rewrites
  `CUDA_VISIBLE_DEVICES` inside the container (see the **device** field
  above) — and say so when no GPU was found (CPU-only: GPU commands
  generate, execution refused).
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
  endpoint (strata, vLLM, llama.cpp, …): **scheme, host, port, api key,
  model id**. `scheme https` speaks TLS to real end-user APIs (OpenAI,
  DeepSeek, Groq, … — a blank port means 443); local servers (strata,
  vLLM) stay `http`. From inside the container, a host-side server is
  reached through the bridge gateway: host `172.17.0.1`.
- **timeout** — the LLM connection timeout in seconds (default `10`,
  range `1..300`): a hung provider fails the generation with
  `LLM provider unreachable: timed out` instead of blocking it.
  `setup.sh` (the published dist) does NOT ask for it — the image
  default is `10` s (`--timeout` exists for non-interactive installs);
  the Config tab has the field.

  **strata on the host (the test setup):** provider `openai`, host
  `172.17.0.1`, port `8080`, api key *empty*, model `qwen3.8-27b`. Thinking models are handled: if the model exhausts
  `max_tokens` in its reasoning trace (empty answer), fass retries once with
  8× the token budget.

**Test LLM** button: sends a one-word probe through the real request path
(`POST /v1/config/llm-test`) and shows the reply + latency, using the values
in the form (no need to save first).

### API key and API/MCP switch

There is **no authentication by default** — anyone who can reach port 8000
can generate commands, execute them and rewrite the config; run fass on a
trusted network or behind an authenticating proxy. The tab's **API key**
section (before Appearance) carries two switches, both live (per-request
config re-read, no restart):

- **API/MCP** (the master ticker, left of the key field) — off, every
  `/v1/*` call answers **404** with the "api is disabled" detail
  (API-absent: the API looks unmapped, not locked) and `fass mcp` refuses
  to start. The switch cannot re-enable itself — with the API off even
  `PUT /v1/config` is 404, so re-enabling is a `config.json` edit
  (`api_mcp_enabled`); the served page shows a banner explaining that.
  The disabled check runs before the key gate, so even a valid Bearer key
  gets 404 while it is off.
- **enable api key** — on, every `/v1/*` call must carry
  `Authorization: Bearer <key>` (key ≥ 16 characters) or gets **401** +
  `WWW-Authenticate: Bearer` (a banner in the page asks for the key). The
  page, `/static`, `/media` and `/keys` routes stay open for the player,
  and `GET /healthz` stays open as a liveness probe.

Both off (the default) = the open API.

### Apply

Recreates the fass container from the saved config so volume/port/GPU
changes take effect (including the `gpu.device` encode pin — refused
with 422 up front if it pins a card the container cannot see), via the
**fass-worker sidecar** (see Self-management below): the UI's POST is forwarded to `fass-worker:8001/swap`, which stops
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

- **off unless `FASS_ALLOW_EXECUTE` is set** — the image sets it; a dev
  checkout never runs anything.
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

## RAG (default service, M13)

`fass-rag` — the lexical retriever over the pinned FFmpeg corpora — is part
of the **default** deployment: `docker compose -f docker/compose.yaml up -d`
brings it up (no profile, no overlay; the old opt-in `docker/compose.rag.yaml`
is retired) and the fass service is wired to it via `FASS_RAG_ENABLED=1` +
`FASS_RAG_URL=http://fass-rag:8100` in the compose environment.

- **The corpus index is baked into the image.** `docker/Dockerfile.rag`
  copies the pinned corpus source (`rag/corpus/ffmpeg-9.0.2` +
  `ffmpeg-6.1.1`) into `/data` and runs `python -m rag.ingest` as a
  build-time step, so the finished `/data/<corpus_id>/` tree (manifest +
  chunks) lives in an image layer. The service starts serving with **no
  volume mount** and no first-boot build.
- **Build prerequisite:** the corpus source (`docs/*.html`,
  `build-facts/*.txt`) is generated data, gitignored by design — run
  `rag/tools/build_corpus.sh` (recipe: `rag/corpus/BUILD-RECIPE.md`) in the
  build context first. A corpus-less context fails the image build loudly.
- **Fail-open (PRD 4.4):** the fass-side client never blocks generation.
  With fass-rag down, `/v1/commands` still succeeds and the evidence block
  records status `unavailable`; `GET /v1/rag` shows the degraded state.
- **Non-dev default:** the code default in `fass/config.py` stays OFF —
  development checkouts don't need the service; docker enables it via env.
- **i7 live rule (PRD 6.7):** i7's live compose carries local opt-ins
  (socket mount, `FASS_DOCKER_MANAGE=1`, GPU pin). Merge the `fass-rag`
  service block and the two `FASS_RAG_*` env lines into it **by hand** —
  never overwrite the file from the repo.

## Database (default service)

`fass-db` — PostgreSQL 16 (`pgvector/pgvector:pg16`, pgvector kept for
the future) — is part of the **default** deployment: it stores ALL
settings values, the whole Runs-tab history (jobs, ids, timestamps,
durations, the command used, the logs) and the worker registry.

- **Defaults:** user `ffmpeg` / password `ffmpeg` / database
  `ffmpeg_assisstant`, host `fass-db` (compose DNS — the port is
  **not** published; only fass talks to it). The dist's `setup.sh` asks
  at install time whether the database stays the default; a custom
  answer records those five values in `config.json` and does not start
  the local `fass-db` service (the external database must exist — fass
  applies the schema to it on first connect). The Config tab's
  **DB, settings and runs** section owns every connection value
  (host / port / user / password / database) — **connect** there
  reconnects after a configuration change and checks the database's
  stored major fass version against this build: an empty database is
  initialised (schema created, seeded from the files, this worker
  registered), a compatible one connects as-is (never re-seeded), and
  a different version is refused with "old db version, do manual
  migration" — a populated database is never migrated automatically.
- **Dual-write, file fallback (fail-open):** the files stay the
  primary store; the database is a mirror. A dead `fass-db` costs a
  UI health warning (the same popup as a lost LLM) — never a blocked
  request or lost data.
- **Schema versioning:** the bootstrap creates a `schema_version`
  table so future migrations can apply incrementally.
- **Worker identity:** each fass docker instance registers a stable
  random UUID (`worker-id.json` beside the config file, surviving
  container recreates); every job records the worker that submitted
  it and the fass version that submitted it. Default role:
  `master+worker`.
- **Data volume:** `${FASS_DB_DIR:-../docker-data/db}` — keep it when
  migrating hosts; it is the only state `fass-db` holds.
- **i7 live rule (PRD 6.7):** i7's live compose carries local
  opt-ins; merge the `fass-db` service block into it **by hand** —
  never overwrite the file from the repo.

### Offline database creation (`scripts/create-db.sh`)

`scripts/create-db.sh` creates the database **without the fass app**:
pulls `pgvector/pgvector:pg16` when the `fass-db` container is not
running and must be started, starts it if missing (the same data dir
`${FASS_DB_DIR:-../docker-data/db}` the compose file mounts, so a
script-started container is exactly the one `compose up` would run),
creates the role + database, and applies the **full fass schema (v2)**
with the major-version stamp.

```sh
scripts/create-db.sh                  # container (if needed) + role + db + schema + stamp
scripts/create-db.sh --status         # read-only state report
scripts/create-db.sh --bare           # role + database only, no tables
scripts/create-db.sh --major 1.618033 # explicit stamp (else FASS_MAJOR_VERSION,
                                      # else the repo's fass/version.py — dev
                                      # checkouts; the published dist has no
                                      # version file, so the db stays un-stamped
                                      # and fass stamps it on first connect)
```

It mirrors the Config-tab **connect** gate, so it is safe at any time:
every statement is `CREATE ... IF NOT EXISTS` / `INSERT ... ON CONFLICT
DO NOTHING` in a single transaction — a complete database is a no-op; a
database stamped with a **different** major version is refused ("do
manual migration", nothing touched); an un-stamped one is stamped the
same way fass would on first connect. The published dist's `setup.sh`
runs it against `fass-db` before the stack comes up. `FASS_DB_CONTAINER`
/ `FASS_DB_NAME` / `FASS_DB_USER` / `FASS_DB_PASSWORD` point it at a
different target; `FASS_DB_DIR` only matters when the script itself
starts the container (a running one is used as-is).

## Tee multi-output (M13.5)

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
[HTTP streams](#http-streams-m136)).

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
asset (the M10.4 flow — main = distorted, the asset = reference), or
name the distorted clip as the `distorted` asset (the web UI's Output
field does this). When the output folder holds no video, the
clarification asks for the distorted file.

## Multicast (host network mode)

Multicast does not reliably cross the compose bridge: a published UDP
port is unicast NAT, and the group has to be joined on the interface
that actually receives it. The reliable setup is to share the host's
network namespace with fass — the container then sees every host
interface, joins the group on the right NIC, and `udp://<group>:<port>`
addresses work exactly as they do on the host. Only `fass` goes
host-mode; the sidecars (`fass-worker`, `fass-rag`) stay on the bridge
publishing their ports to `127.0.0.1`, which fass reaches through the
host netns.

**Enabling it:** no installer flag — it is a machine-local overlay. In
host mode the machine-local overlay `docker/compose.local.yaml` (merged
with the GPU-reservation part when both apply) gains:

- `fass: network_mode: host` — fass binds 8000 on the host directly (the
  base `${FASS_UI_PORT:-8000}:8000` ports entry is discarded by docker
  with a warning)
- `FASS_DOCKER_WORKER=127.0.0.1:8001` + `FASS_RAG_URL=http://127.0.0.1:8100`
  on fass (compose merges environment maps key-by-key over the base list
  entries)
- `127.0.0.1:8001:8001` / `127.0.0.1:8100:8100` on the sidecars
- fass-http (the http stream sidecar) is untouched — bridge + its port

**Verifying** — at startup fass runs `ip link show <name>` on every
interface inside the container and looks for `MULTICAST` in the flag
list (the result goes to the container log and to `GET /v1/env`). The
Config tab shows a green/red **multicast** indicator in the *Streaming
— port mappings* section — the interfaces with the flag are listed next
to it. (Linux sets the flag by default, so it stays green in bridge
mode too; host mode is still what makes the HOST's groups reachable —
the indicator tells you the kernel side is multicast-capable.)

**Host firewall** — in host mode fass's traffic is host traffic, so the
host firewall decides. UDP multicast to the group's port must be
allowed, e.g. with UFW: `sudo ufw allow 1234/udp` (per port). Without
the rule a receiver fails silently — zero bytes, no error.

**Worked example** — an H.264 stream at group `239.1.1.1:1234`, host NIC
`192.168.0.30`. Sender, on the host:

```sh
ffmpeg -re -f lavfi -i testsrc=duration=300:size=640x360:rate=25 \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -f mpegts "udp://239.1.1.1:1234?localaddr=192.168.0.30"
```

Receiver, in fass (Runs tab, Enter mode — `-t 60`: the validation gate
wants a number of seconds, not `00:01:00`):

```sh
ffmpeg -i "udp://239.1.1.1:1234?localaddr=192.168.0.30&fifo_size=1000000&overrun_nonfatal=1" \
  -t 60 -c copy /output/multicast.ts
```

`localaddr=<host IP>` pins the interface the group is joined on (it
matters with several NICs); `fifo_size=1000000&overrun_nonfatal=1`
absorbs arrival bursts so a joiner that lands mid-stream recovers
instead of failing. Multicast **output** is symmetric — a command
destination can be `udp://<group>:<port>?localaddr=<host IP>`.

## HTTP streams (M13.6)

HLS/DASH runs destined for browser playback are served by the
**fass-http** sidecar — a plain `httpd:2.4-alpine` static server that is
part of the default deployment: `docker compose -f docker/compose.yaml
up -d` brings it up together with fass (no profile, no overlay).

- The **whole output volume** is mounted read-only at the sidecar's
  htdocs root, so a file at `{output}/http/<run-id>/stream.m3u8` is
  served at `http://<host>:<port>/http/<run-id>/stream.m3u8` — the URL
  maps 1:1 onto the file, nothing is rewritten.
- The sidecar's host port comes from `docker/.env`
  (`FASS_HTTP_PORT`, default `8001` — `8080` is often taken by local
  LLM servers; fass owns the web UI port, `FASS_UI_PORT`, default
  `8000`; fass-rag stays internal on `8100` and is not published).
  `setup.sh` (the published dist) asks for it, writes it to `.env`, and
  creates the `<output>/http/` folder.
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
- The FFmpeg tab's **play2** (live side-by-side HLS, run through
  `bash /opt/play2/sbs_hls_{cpu,nvidia}.sh`) uses the sidecar too: a
  fixed stream tree `{output}/http/play2/` — wiped and recreated on
  every start, `http/play2/stream.m3u8` **live** in the Player tab while
  the run runs (stop = process-group kill; stopping it in the Player tab
  flips the FFmpeg tab's play2 toggle back). Full spec: the main README's
  [play2](../README.md#play2--live-side-by-side-sbs-hls) section.
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
(`docker/launcher.sh start|rebuild`). A first-time sidecar, or a changed
`FASS_HTTP_PORT`, takes effect on the next start/rebuild. `launcher.sh`
re-syncs `docker/.env` from `config.json` before every up and preserves
every non-volume line, so `FASS_HTTP_PORT` (like `FASS_GPU`) survives.
On i7's live compose the fass-http block is merged **by hand**, like
the fass-rag block.

## Development vs deployment

| | dev checkout | docker image |
|---|---|---|
| execution | off (env gate) | on (`FASS_ALLOW_EXECUTE=1`) |
| config file | `./.fass-config.json` | `/config/config.json` (seeded) |
| volumes | cwd / local paths | `/input` `/output` `/log` mounts |
| FFmpeg | whatever is on PATH | 9.0 + nvenc, in the image |
| RAG | off (code default) | on (`FASS_RAG_ENABLED=1`, baked index) |

Both run the same code; the difference is environment, not code paths.
