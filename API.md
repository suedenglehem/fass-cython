# fass HTTP API

`fass serve` (and the docker image) runs a JSON API built on FastAPI. The
single-page web UI is just one of its clients — everything the tabs do can be
done with curl.

Base URL: `http://<host>:8000` (the `fass` service; in the compose stack the
sidecars reach it on `http://fass:8000`).

**Conventions**

- Every *domain* outcome of a command generation is a structured **200** with
  a `status` field — `ready`, `needs_clarification`, `unsupported`, `error`
  (`cancelled` when an in-flight generation is aborted). 4xx is reserved for
  malformed requests (FastAPI answers 422 for a bad body before your code
  runs).
- **Execution is off unless enabled.** `POST /v1/runs` only works with
  `FASS_ALLOW_EXECUTE=1` (the docker image sets it; a bare `fass serve` does
  not). Generation, file listing, config, … always work.
- **No authentication by default; an optional API key can lock the
  control API, and an API/MCP master switch can take it down.** Out of
  the box, every `/v1/*` endpoint — including the ones that execute
  ffmpeg and rewrite the deployment config — is open to anyone who can
  reach port 8000. The Config tab's **API key** section
  ([Config & self-management](#11-config--self-management)) can require
  `Authorization: Bearer <key>` on every `/v1/*` call (401 otherwise),
  and its **API/MCP** master ticker can switch the whole API off —
  every `/v1/*` route then answers 404 (API-absent) and `fass mcp`
  refuses to start. The page, `/static`, `/media` and `/keys` routes
  stay open either way — they serve the player, they are not the
  control API. Either way, run fass on a trusted network, or put an
  authenticating proxy (reverse proxy with token/OAuth) in front of it.
  Bind address: `fass serve --host/--port`.

File names in the examples below are *bare basenames* of the deployment
volumes (`$FASS_INPUT_DIR` / `$FASS_OUTPUT_DIR`, `/input` `/output` in the
container). A `-i <file>` prefix is accepted everywhere a filename is taken.

## Contents

0. [Authentication (API key)](#authentication-api-key)
1. [Health & build info](#1-health--build-info)
2. [Generate a command](#2-generate-a-command)
3. [Execute a command](#3-execute-a-command)
4. [Player streams](#4-player-streams)
5. [VMAF / quality scoring](#5-vmaf--quality-scoring)
6. [Bitrate visualisation (vviz)](#6-bitrate-visualisation-vviz)
7. [Media info](#7-media-info)
8. [Files](#8-files)
9. [Presets](#9-presets)
10. [RAG](#10-rag)
11. [Config & self-management](#11-config--self-management)
12. [Volumes](#12-volumes)
13. [Encryption keys](#13-encryption-keys)
14. [Media serving](#14-media-serving)
15. [Run logs](#15-run-logs)
16. [UI](#16-ui)
17. [Database (PostgreSQL)](#17-database-postgresql)

---

## Authentication (API key)

The Config tab's **API key** section (between RAG and Appearance)
carries the control API's two switches: the **API/MCP** master ticker
(to the left of the key field) and the **enable api key** ticker +
**fass api key** field — at least **16 characters** when enabled (a
shorter/blank key with the ticker on is rejected: 422 on
`PUT /v1/config`, "Save refused" in the UI).

**The API/MCP master switch.** Off, the entire control API is gone:
every `/v1/*` route answers **404** — API-absent, the API looks
unmapped, not locked, for anything scanning it (404 beats 401 even with
a valid key):

```
HTTP/1.1 404 Not Found

{"detail": "the fass api is disabled (api_mcp_enabled=false in the config)"}
```

`fass mcp` refuses to start (error on stderr, exit 1). The web page
(`/`), `/static/`, `/media/`, `/keys/` and `GET /healthz` stay open. The
switch is **on by default** (a config file without the field behaves as
on), is re-read per request, and — because the API is the only writer
of the config — **can only be re-enabled by editing the config file on
the server**: with it off, even `PUT /v1/config` is 404. The web UI
shows a banner with the re-enable instruction when it sees the 404
detail.

| field               | type | default | meaning                                                            |
|---------------------|------|---------|--------------------------------------------------------------------|
| `api_mcp_enabled`   | bool | `true`  | when `false`, every `/v1/*` route is 404 and `fass mcp` won't start |

**Scope — only the control API.** With the master switch on and the key
ticker on, every `/v1/*` route requires the key. The web page (`/`),
`/static/`, `/media/` and `/keys/` are content serving for the player
and stay open, and `GET /healthz` stays open as a liveness probe. With
the key ticker off — the default — the API is open exactly as before
(while the master switch is on).

**Transport.** The key is a credential, sent as a Bearer token:

```
Authorization: Bearer <key>
```

The scheme is case-insensitive and surrounding spaces are tolerated
(`BEARER  <key>` works). The comparison is constant-time. A wrong,
missing or scheme-less header gets:

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer

{"detail": "invalid or missing api key"}
```

**Live toggle.** The saved config is re-read on every request, so
enabling or disabling takes effect on the *next* request — no Apply, no
restart.

**The key in the config.** `GET /v1/config` returns it clear in
`config.api` (the same precedent as `llm.api_key`); `PUT /v1/config`
takes the whole `api` block back:

| field         | type  | default | meaning                                             |
|---------------|-------|---------|-----------------------------------------------------|
| `api.enabled` | bool  | `false` | when `true`, every `/v1/*` call must carry the key |
| `api.key`     | str   | `""`    | the key; ≥ 16 chars required when enabled          |

**The web UI.** The page keeps the key in the browser (localStorage),
sends it automatically with every `/v1/*` fetch, and pops a
key-entry banner at the top of the page when a 401 comes back — a
rejected key is prefilled for correction. The player and media keep
working regardless, since their routes are open.

```sh
KEY='0123456789abcdef'   # ≥ 16 characters — yours, not this one

# a gated call
curl -s http://localhost:8000/v1/streams \
  -H "Authorization: Bearer $KEY" | jq

# enable it — GET, change, send back (PUT replaces the whole config):
cfg=$(curl -s http://localhost:8000/v1/config | jq '.config')
curl -s -X PUT http://localhost:8000/v1/config \
  -H 'content-type: application/json' \
  -d "$(echo "$cfg" | jq --arg k "$KEY" '.api = {enabled: true, key: $k}')"

# from the next request on, every /v1/* without the header is 401
curl -s -i http://localhost:8000/v1/streams | sed -n '1p'
# HTTP/1.1 401 Unauthorized

# the page and its content stay open
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/healthz
# 200

# master switch off — the API is gone, so it is the config FILE that
# changes ("api_mcp_enabled": false), not the API:
curl -s -i http://localhost:8000/v1/streams | sed -n '1p'
# HTTP/1.1 404 Not Found
```

---

## 1. Health & build info

### `GET /healthz`

Liveness probe (the docker healthcheck). → `{"ok": true}`

### `GET /v1/env`

Build info + the probe of the ffmpeg this process uses: version/build string,
fass version, which encoders/filters/bitstream-filters of the registry are
present in *this* build (CPU, GPU `*_gpu`, QSV `*_qsv` variants), whether
execution is enabled, the saved GPU config, and the multicast startup check.

```sh
curl -s http://localhost:8000/v1/env | jq '{version, available, execution, multicast}'
# {"available": true, "execution": true, "multicast": {"ok": true}, "version": "1.618033.738dce2"}
```

### `GET /v1/support`

The full capability surface (registry-driven): supported output modes, the
container/codec matrix with defaults, subtitle dump formats, the video/audio
filter allowlists and the full filter table (option kinds, ranges, choices),
per-container format options, stream schemes, pixel formats, profiles,
presets, sample-rate and speed limits. This is the machine-readable answer to
"what can this fass do?".

```sh
curl -s http://localhost:8000/v1/support | jq '.summary'
```

### `GET /v1/prompts`

The last 1000 instructions the model accepted (`status: ready`), newest first
— the Info/Log tab's *prompts* view. → `{"prompts": [...]}`

```sh
curl -s http://localhost:8000/v1/prompts | jq '.prompts[0]'
```

---

## 2. Generate a command

### `POST /v1/commands`

The core endpoint: natural-language instruction + assets → validated ffmpeg
argv. Response is a 200 with `status`:

- `ready` — `command` (a string), `arguments` (the argv array, what you pass
  to `/v1/runs`), `output_filename`, optional `warnings`, `summary`,
  `checks`, `validation_level`.
- `needs_clarification` — `questions`; answer them (or reword) and re-POST.
- `unsupported` — `reason`.
- `error` / `cancelled`.

Body fields:

| field | meaning |
|---|---|
| `instruction` | the natural-language request (1–4000 chars) |
| `assets` | asset id → path or stream URL (`http(s)://`, `rtmp(s)://`, `rtsp(s)://`, `srt://`, `rist://`, `udp://`, `rtp://`, `tcp://`); may be a string or `{"path": …, "kind": …}` (kind needed for extensionless stream URLs); `-i <file>` values name files of the input folder. **Must include `main`** (the input video). `watermark` must name an **image** (`.png` `.jpg` `.jpeg` `.webp` `.gif` `.bmp`) — any other kind is a `422`. For quality comparisons `main` is the reference and the distorted clip is auto-detected in the output folder (bind `distorted` to name it explicitly) |
| `output_filename` | output filename, or a stream URL to send the output to; `/input/…` writes into the input folder (chained processing); a relative name with `/` is an output subfolder |
| `adapter` | `auto` (default) / `rules` / `llm` |
| `preflight` | `true` = also run the preflight check after generation |
| `verbose` | `true` = runs use `-loglevel verbose`, log goes to `{output}/log/` |
| `generation_id` | client-chosen id; while the request is in flight you can `POST /v1/commands/cancel` with it and poll `GET /v1/commands/progress` |
| `previous_plan` | for a `needs_clarification` follow-up: your answers |
| `media` | pre-collected ffprobe JSON for the input (skip re-probing) |

```sh
curl -s -X POST http://localhost:8000/v1/commands \
  -H 'content-type: application/json' \
  -d '{
    "instruction": "make it 720p for web",
    "assets": {"main": "-i input.ts"},
    "output_filename": "output_720p.ts",
    "generation_id": "gen-001"
  }' | jq '{status, command, warnings}'
```

### `POST /v1/commands/cancel`

Abort an in-flight generation (the blocking LLM round-trip may already be
running to its own timeout — its reply is discarded). 404 when no generation
with that id is in flight. Body: `{"generation_id": "gen-001"}`.
→ `{"ok": true, "generation_id": "gen-001"}`

### `GET /v1/commands/progress?generation_id=…`

The live stage of an in-flight generation: `started`, `probing input`,
`planning`, `building command`, `validating command`, `preflight check`.
404 once it finished — the POST response is the final word.
→ `{"stage": "validating command"}`

```sh
curl -s 'http://localhost:8000/v1/commands/progress?generation_id=gen-001'
```

---

## 3. Execute a command

### `POST /v1/runs`

Execute an argv. Body:

| field | meaning |
|---|---|
| `arguments` | the argv array from a `ready` command (or the final step's argv for a multi-pass plan). **Exactly one of `arguments` / `command` is required** |
| `command` | expert override: the edited command string, shlex-split server-side and through the same validation gate |
| `steps` | multi-pass plan: every pass's argv in execution order, final pass last; `arguments` must equal `steps[-1]` |
| `timeout` | optional wall-clock limit, seconds (≤ 86400; with `steps` it applies per step) |
| `verbose` | log to `{output}/log/` (recorded in the run record; the UI restores it from the newest run at page boot) |
| `preflight` | run the preflight validation against the local FFmpeg build first (default `false`; recorded in the run record and restored like `verbose`) |
| `serve_http` | output goes to the fass-http sidecar: the playlist is placed in the per-run dir `{output}/http/<run-id>/` |
| `instruction` | recorded in the run-log footer so the log is self-describing |

The process is capped by the saved *ffmpeg process max time*
(`ffmpeg.max_seconds`, default 6 h, 0 = unlimited) and runs in its own
process group — stop kills the group.

```sh
curl -s -X POST http://localhost:8000/v1/runs \
  -H 'content-type: application/json' \
  -d '{"arguments": ["ffmpeg", "-y", "-i", "/input/input.ts",
       "-vf", "scale=-2:720", "-c:v", "libx264", "-c:a", "aac",
       "/output/output_720p.ts"]}'
```

### `GET /v1/runs?limit=0&offset=0&q=`

Executed commands, newest first. `limit > 0` serves one page; `total` is the
overall count; `system` is the machine's current CPU/GPU load readout.
`q` is an optional case-insensitive substring filter applied to each run's
`command` string (before paging) — search by input or output file name, or
any other keyword in the command; blank / whitespace-only is a no-op.

### `GET /v1/runs/{run_id}`

One run record: argv, status, exit, timestamps (`started`, and `finished` —
stamped when the run leaves `running`), log path, stream path (if it writes
a playlist), output file, and the recorded `verbose` / `preflight` flags.
Every record also carries `worker_id` (the fass docker instance that
submitted the job — a stable random UUID persisted beside the config file)
and `fass_version` (the fass version that submitted it). Records created
before these fields existed carry `null`.

### `GET /v1/runs/{run_id}/log`  *(text/plain)*

The run's log. Display-capped: a log over 10 000 lines is served as its last
1000 + banner; the on-disk file always keeps the full output.

### `POST /v1/runs/{run_id}/stop`

Stop the run: SIGTERM the run's exact process group, SIGKILL after ~5 s if it
survives. → `{"stopped": true|false}`

### `POST /v1/runs/{run_id}/rerun`

Rerun a finished run with its exact recorded argv/steps. Missing local inputs
are re-fetched from the mapped input remote; a successful rerun's output/log
are uploaded to the mapped remotes by the standard post-run sync. Returns the
new run record. 409 for a VMAF attempt record (re-score from the VMAF tab
instead).

```sh
curl -s -X POST http://localhost:8000/v1/runs/<run_id>/rerun | jq '.run.id'
```

### `POST /v1/ffmpeg/stop-all`

**Emergency stop** (the Config tab's red button): kill every ffmpeg process
fass owns — the tracked run attempts, the VMAF job's current attempt, then a
`/proc` sweep for strays (in a container: every ffmpeg there; on a bare
host: only fass's own descendants, never the user's unrelated ffmpeg). No
confirmation, by design.

```sh
curl -s -X POST http://localhost:8000/v1/ffmpeg/stop-all
```

---

## 4. Player streams

### `GET /v1/streams`

The http-served stream tree: every `.m3u8` (kind `hls`) and `.mpd` (kind
`dash`) under the output volume's `http/` subdir, recursive, newest first.
Each entry: `path` (output-relative), `url` (the `streaming.http_base_url`
prefix — the fass-http sidecar mounts the whole output volume, so the URL is
served as-is), `size`, `modified`, `live` (the owning run is still running /
writing), plus the whole tree's `total_size` / `file_count`.

```sh
curl -s http://localhost:8000/v1/streams | jq '.streams[0]'
```

### `POST /v1/streams/purge`

Wipe the http-served tree (`{output}/http/`, recursive). Optional body
`{"path": "http/<BASE>/<BASE>.m3u8"}` purges just that stream's dir;
`"dry_run": true` counts without deleting. 409 while the producing run is
still running (whole tree: any running run; one dir: only its run).
→ `{"removed": <file count>, "size": <bytes>}`

```sh
curl -s -X POST http://localhost:8000/v1/streams/purge \
  -H 'content-type: application/json' \
  -d '{"dry_run": true}'
```

### `POST /v1/streams/hls-play`

Transcode one volume file to a single-bitrate HLS stream — H.264 1080p50 at
the configured *bitrate play file* (default 3000 kbps) + AAC-LC 128 k, 2 s
segments, rolling 5-segment window — into the per-source player dir
`{output}/http/{BASE}/`. `h264_nvenc` on GPU-enabled deployments (CPU
fallback with a run note). 409 when that source is already playing.

```sh
curl -s -X POST http://localhost:8000/v1/streams/hls-play \
  -H 'content-type: application/json' \
  -d '{"dir": "input", "name": "input.ts"}'
```

### `POST /v1/streams/play2`

Live side-by-side (SOURCE | DERIVED) HLS: the Input file on the left, the
Output file on the right, at the fixed playlist
`{output}/http/play2/stream.m3u8` (wiped + recreated on every start). The
video pipeline and encoding are owned by the baked-in bash script
(H.264 CBR at the *bitrate play2* field, default 5 M, + AAC 128 k, looping
both inputs forever); fass only launches it. GPU variant iff `gpu.enabled`
and `h264_nvenc` exists. Stop = the ordinary run stop. 409 when a play2 run
is already active.

```sh
curl -s -X POST http://localhost:8000/v1/streams/play2 \
  -H 'content-type: application/json' \
  -d '{"input": "input.ts", "output": "output_720p.ts"}'
```

---

## 5. VMAF / quality scoring

### `POST /v1/vmaf`  → **202**

Pointwise VMAF of `distorted` against `reference` (bare filenames of the
input/output volumes; streams and playlists are a 400). GPU-first routing
with a CPU fallback, scored over the shorter file. Body:

| field | meaning |
|---|---|
| `reference`, `distorted` | bare filenames (input / output volume) |
| `mode` | `auto` (default) / `cpu` / `gpu` |
| `confirm` | `true` to override the 409 advisories |

The first call answers **409** with an advisory when the durations differ by
more than 0.25 s (score over the shorter file on confirm) or the reference is
above 4K (score at 4K dimensions with the 4K model on confirm); re-POST with
`confirm: true`.

```sh
curl -s -X POST http://localhost:8000/v1/vmaf \
  -H 'content-type: application/json' \
  -d '{"reference": "input.ts", "distorted": "output_720p.ts", "mode": "auto"}'
# {"job_id": "…"}   (202)
```

The score is kept in the scores volume as `<uuid4>.json` and appended to
`master.txt`; a scores remote mapping gets both files after every score
(best-effort).

### `GET /v1/vmaf/{job_id}`

Poll the job: `status` `queued` → `scoring` (live "N frames, HH:MM:SS"
progress + percent) → `done` / `error` / `cancelled`; the finished `result`
is the score payload (libvmaf JSON as-is, the exact command, the
human-readable steps).

### `POST /v1/vmaf/{job_id}/cancel`

Stop a running job: the worker's flag is set (no further chain is started)
and the live attempt's process group is killed. A finished job is a no-op.
→ `{"cancelled": true|false, "status": …}`

---

## 6. Bitrate visualisation (vviz)

### `POST /v1/vviz`

vviz_py's interactive frame/GOP/bitrate chart on one video file. vviz reads
mp4 only, so a non-mp4 source is losslessly remuxed to a temp mp4 in the
output volume first (409 + `needs_confirm` when the remux would be long —
re-POST with `"confirm": true`; 507 when the volume lacks the space). Video
codec must be h264/hevc/av1/vp9 (400 otherwise). 503 when vviz is not
installed on the build. On success the self-contained Plotly HTML comes back
for the client to embed.

```sh
curl -s -X POST http://localhost:8000/v1/vviz \
  -H 'content-type: application/json' \
  -d '{"target": "output", "file": "output_720p.ts"}'
```

---

## 7. Media info

### `GET /v1/mediainfo?target=input&file=<name>`

ffprobe's own JSON report on a file of the input (default) or output volume.

### `GET /v1/tsanalyze?target=output&file=<name>`  *(text/plain)*

The tsanalyze tool's (tsduck suite) full report on an MPEG-TS file. The file
must probe as mpegts first (tsanalyze is TS-only). 400/404/502 on bad
target/file/ffprobe-missing.

### `GET /v1/files/inspect?dir=input&file=<name>&tool=ffprobe`

Media info for one file through the named tool: `ffprobe` (same JSON the
planner reads) or `mediainfo` (503 when the binary is absent). A file may be
a bare basename or an http set's manifest subpath (`clip/clip.m3u8`).

```sh
curl -s 'http://localhost:8000/v1/files/inspect?dir=input&file=input.ts' | jq '.streams[0].codec_name'
```

### `POST /v1/files/frame`

The file's first frame as a base64-encoded JPEG (360 px high). Fail-open: a
file with no video stream, a failing ffmpeg, a timeout → 200 with
`{"ok": false, "error": …}`. Body: `{"dir": "input", "file": "input.ts"}`.

---

## 8. Files

### `GET /v1/files?dir=input&limit=0&offset=0&pattern=&sort=date`

Top-level regular files of one volume, paginated server-side (`limit=0` =
whole list; `total` = every file, `matched` = the pattern's set, `files` =
the window). `pattern` is a regexp over names (bad pattern → 400). `sort`:
`date` (default, newest first) / `name` / `size`. An unmounted volume →
`{"exists": false, …}`. An http set (a run's own subfolder) is presented by
its manifest(s) only.

### `GET /v1/files/glob?pattern=*.ts`

Batch mode: the matched **input** files for a glob (`fnmatch` semantics over
bare names, `*` required, no `/`; 400 otherwise), sorted alphabetically —
the first entry is the file the command is generated for, the rest run from
the same string.

### `GET /v1/files/disk`

Free space of both deployment volumes: `{"input": {"exists": true, "total":…, "used":…, "free":…}, "output": {…}}`.

### `POST /v1/files/copy-to-input`

Copy a file from the output volume into the input volume (feed a processed
result back as the next run's input). Body: `{"name": "output_720p.ts"}`.
409 when the name already exists in the input folder — never silently
overwrites. The output original survives (copy, not move).

---

## 9. Presets

A preset freezes one successful generation (instruction + inputs + command)
into `<md5>.json` in the presets dir — re-saving the same generation lands on
the same file (idempotent).

### `GET /v1/presets`

Every preset, newest first. → `{"presets": [{"name", "instruction", "command" (120-ch preview), "saved_at", "size"}], "dir": …}`

### `POST /v1/presets`

Save the whole state of a generation. Body: `instruction`, `assets`,
`command`, plus the result-pane fields (`output_filename`, `adapter`,
`preflight`, `verbose`, `servehttp`, `arguments`, `summary`, `defaults`,
`warnings`, `validation_level`, `checks`, `evidence`). The filename is
derived server-side.

### `GET /v1/presets/{name}`

One preset's raw JSON text (name = the 32-hex `.json` filename — the
traversal guard). 404 unknown, 500 corrupt.

---

## 10. RAG

Both endpoints are fail-open: RAG disabled, a dead service, or any client
error answer 200 with `ok: false` + a human-readable `error` — the tab
renders the degraded state as a line.

### `GET /v1/rag`

Read-only RAG state for the Config tab: the resolved client config plus a
2 s probe of the service's corpus list (`service.ok` / `service.error`).

### `POST /v1/rag/query`

One search against the fass-rag service. Body:

| field | meaning |
|---|---|
| `query` | the question (1–2000 chars, not whitespace-only) |
| `top_k` | chunks for this query (service caps at 8) |
| `source_kinds` | `["manual", "build_help"]` — default both |
| `llm` | `true` (default) = append the configured LLM's answer to the same question (`llm_answer` / `llm_warning` in the response) |

→ `{"ok": true, "corpus_id": …, "chunks": […], "retrieval_ms": …, "warnings": […]}`

```sh
curl -s -X POST http://localhost:8000/v1/rag/query \
  -H 'content-type: application/json' \
  -d '{"query": "how do I add subtitles", "llm": true}' | jq '.chunks | length'
```

---

## 11. Config & self-management

### `GET /v1/config`

The saved config (`config`), its `path`, the generated compose preview
(`compose`), the LLM/docker status, per-volume folder presence on the host
(`volumes_status`), the encode card + free VRAM (`gpu_card`), and the
current database status (`db_status` — `{ok, detail, schema_version}`,
the same shape as `GET /v1/db/ping`).

### `PUT /v1/config`

Persist a config change — the body is a **patch**: keys you send are set,
keys you omit **keep the stored value** (nested sections merge the same
way; lists replace wholesale; `null` is an explicit set, e.g.
`{"llm": {"port": null}}` un-configures the port). Sending the **whole**
`FassConfig` (GET it, change, send back) is fine too — the UI does. A
rejected body (unknown key, bad shape) never writes anything. The next
request uses it, no restart. 409 guards a changed volume dir. Changing the
LLM endpoint (provider/host/port/scheme/model/key) triggers the
thinking-capability probe.

```sh
# one-field edit — everything else is untouched
curl -s -X PUT http://localhost:8000/v1/config \
  -H 'content-type: application/json' \
  -d '{"gpu": {"device": "1"}}'
# or the full round-trip
cfg=$(curl -s http://localhost:8000/v1/config | jq '.config')
curl -s -X PUT http://localhost:8000/v1/config \
  -H 'content-type: application/json' \
  -d "$(echo "$cfg" | jq '.ffmpeg.max_seconds = 7200')"
```

### `POST /v1/config/apply`

Ask the fass-worker sidecar to **recreate this container** from the saved
config (docker deployments only). The worker stops *this* container to run
the swap — expect the connection to drop after the ack, then poll
`/v1/config/apply-result`. 409 when the sidecar is not reachable
(`FASS_DOCKER_WORKER`), 502 when it is. Before the swap the saved
`gpu.device` is checked against the GPUs this container can see: a pin
outside that set is **422** (the replacement would come up unable to
encode); when enumeration is unavailable the check fails open.

### `GET /v1/config/apply-result`

The sidecar's last recorded apply state (404 before the first apply). A
fresh Apply rewrites the state file CLEAN — the `error` key appears only
under `status: "failed"` (the endpoint also withholds `error` under any
other status, so a previous failure's text can never ride a later
success).

### `POST /v1/config/llm-test`

One-word completion against the LLM — tests the **saved** config, or the
**unsaved** form values with `{"use_unsaved": true, "llm": {…}}` (the
Config-tab button). 422 with the exact sentence "OpenAI-compatible LLM
needs host, model and a port (with https, a blank port means 443)" when
the openai block is incomplete — the Config tab answers that case with
the blue sticky popup, nothing next to the button. The
test doubles as the thinking-capability probe → also returns
`thinking_supported` (`true` / `false` / `null` = undetected).

```sh
curl -s -X POST http://localhost:8000/v1/config/llm-test | jq '{ok, model, seconds, thinking_supported}'
```

### `GET /v1/config/gpu-test`

Live GPU diagnostics (`nvidia-smi -L` from the fass environment). `ok` /
`detail` — always 200; `ok: false` is a finding, not a server error.

### `GET /v1/gpus`

The GPU re-select dropdown data: `devices` — every GPU **visible from the
container** as `{index, name, uuid, mem_total_mib, mem_free_mib}`
(`[]` on a CPU-only install or when nvidia-smi fails), `pin` — the current
`CUDA_VISIBLE_DEVICES` (`"all"` = no pin is set in the environment),
`gpu_enabled`. Save a
selected `index` into `gpu.device` (PUT `/v1/config`) and Apply to move
encoding onto it. `gpu.device` `"all"` KEEPS the pin the container
already runs with — an Apply never moves the encode card by itself.

```sh
curl -s http://localhost:8000/v1/gpus | jq '.devices[] | [.index, .name, .mem_free_mib]'
```

### `POST /v1/config/remote-test`

Test one volume's remote mapping — the **unsaved** block is what is tested
(`{"which": "input", "remote": {…}}`), so credentials can be verified before
saving. A `none` block tests the saved mapping instead; a volume with no
mapping at all reports so without touching the network.

### `GET /v1/llm/ping`

Light LLM reachability probe for the UI's 20 s health poll: a `GET
/v1/models` on the endpoint (no tokens, ~4 s timeout), not the heavy
completion. `configured: false` = rules-only deployment (no warning
expected); only `configured && !ok` means "LLM down".

---

## 12. Volumes

### `GET /v1/volumes/free`

Free space on the /output volume in GB (probes the configured host path,
falls back to the container mount `/output`). The UI polls it every 30 s and
warns when `free_gb` drops below the saved `volumes.min_output_free_gb`.
→ `{"output": …, "free_gb": …, "total_gb": …, "error": null}`

---

## 13. Encryption keys

### `GET /keys/{name}`

The app serves its own encryption key over http — no separate web server.
Only two names exist: `encryption.key` (the 16-byte AES-128 key, written when
`hls.aes128_key` is set in the Config tab) and `keyinfo.txt` (its
`-hls_key_info_file`: URI, method, IV). The `EXT-X-KEY` URI ffmpeg writes
into encrypted VOD HLS manifests points at
`http://<host>:8000/keys/encryption.key` — so an HLS player fetches the key
through this route. 404 for anything else (no key configured = 404, the
honest answer).

```sh
curl -s http://localhost:8000/keys/keyinfo.txt
```

---

## 14. Media serving

### `GET /media/output/{filename}`

A file of the /output volume, served for download (browser preview works for
video). 404 when absent.

### `GET /media/run/{run_id}/output`

The run's output file, whichever volume it landed in — /output, or the input
folder for a chained processing (`/input/<name>`).

---

## 15. Run logs

### `GET /v1/logs`

The run logs on this deployment: the runs dir (kind `run`) and the verbose
logs in `{output}/log` (kind `verbose`), newest first. → `{"logs": […]}`

### `GET /v1/logs/orphaned`

Logs whose source files are gone — the purge candidates. →
`{"orphaned": [names], "total": <log count>}`

### `POST /v1/logs/purge`

Delete every orphaned log (run records are kept). → `{"purged": [names]}`

### `GET /v1/logs/{name}`  *(text/plain)*

One log file by basename, display-capped like the run log (last 1000 lines +
banner over 10 000; on-disk file always full).

---

## 16. UI

### `GET /`

The single-page web UI (HTML, self-contained — the vendored shaka-player and
plotly come from `/static/`, no CDN).

### `GET /static/{name}`

Fixed allowlist only: `shaka-player.compiled.js` (shaka-player 5.3.2) and
`plotly.min.js` (plotly.js 3.0.1). Anything else → 404 (no directory
browsing).

---

## 17. Database (PostgreSQL)

The PostgreSQL mirror of the settings and the whole Runs-tab history
(schema: `schema_version`, `settings`, `runs`, `run_logs`, `workers`).
The files stay the **primary** store — every setting change and every run
record is dual-written to the database; a lost database never blocks or
loses anything, so all three endpoints are **fail-open: always 200, with
`ok: false` and a `detail` explaining why** when the database is down or
unconfigured. They live under `/v1/*`, so with the **API/MCP** master
switch off they 404 like every other API route.

The connection parameters (host, port, user, password, database name)
are the Config tab's **DB, settings and runs** section — part of the
normal `config` object, saved with the rest of it by `PUT /v1/config`.

### `GET /v1/db/ping`

The 20 s UI health poll (the `/v1/llm/ping` pattern): a cheap connect +
`SELECT 1`. `ok: false` drives the "database down" warning — the UI applies
the same transition logic as the LLM one (popup on first-load-down and every
up→down, silent recovery).

```json
{"ok": true, "detail": "connected to ffmpeg_assisstant@fass-db:5432 as ffmpeg",
 "schema_version": 2}
```

### `POST /v1/db/check`

The Config tab's **check connection** button: a fresh probe plus what is
actually in the database — the tables present, the applied schema version,
the database's major fass version (the stamp it was initialised with),
and the registered worker count.

```json
{"ok": true,
 "detail": "connected to ffmpeg_assisstant@fass-db:5432 as ffmpeg",
 "tables": {"schema_version": true, "settings": true, "runs": true,
            "run_logs": true, "workers": true, "meta": true},
 "schema_version": 2, "db_major_version": "1.618033", "workers": 1}
```

### `POST /v1/db/connect`

The Config tab's **connect** button — for after a db configuration change
(new host / user / password / database): reconnects with the saved config
without a restart (clearing a stale "down" backoff) and checks schema
compatibility — the database's stored **major fass version** (the `meta`
table; in `v1.618033.6638fa2` the `1.618033` part, the commit-sha part is
the minor) must match this build's major number. An **empty** database is
initialised (schema created and stamped, seeded from the existing files,
this fass registered as a worker); a **compatible** database connects
as-is and is never re-seeded; a **different** version is refused —
nothing is migrated or touched automatically. The UI shows `detail` on
its status line and pops the mismatch up.

`status` is machine-readable: `"init"` (empty database initialised) |
`"ok"` (connected, compatible) | `"old"` / `"newer"` (version mismatch,
refused — `detail` carries "old db version, do manual migration" /
"new db version, do manual migration") | `"no-conn"` (unreachable or
file-only).

```json
{"ok": true, "status": "init",
 "detail": "connected — initialised (schema up to date (v2)) (this worker: registered)",
 "db_major_version": "1.618033", "major_version": "1.618033",
 "seeded": {"settings": 13, "runs": 0, "logs": 0}}
```

`seeded` is `null` when the database already had data (a plain compatible
connect — nothing re-seeded). When the database is down, all three return
`ok: false` with the connection error in `detail`; when psycopg2 is not
installed (file-only development runs) `check` / `connect` report
`"psycopg2 not installed (file-only mode)"`.

---

*Generated from the fass source; the endpoint set and field names follow
`fass/api.py` of the current release.*
