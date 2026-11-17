# fass — natural language → validated FFmpeg commands

`fass` turns a plain-English editing request into a **validated** FFmpeg
command — and, by default, stops there: it never executes. A parser
(deterministic rules by default, optional LLM) produces a strict, schema-bound
*edit plan*;
a deterministic planner and builder turn the plan into an argv array. The
model never produces shell — argv is the source of truth, and a POSIX
rendering is derived from it (`shlex.join`), never parsed back.

```
instruction ──> NLU (rules | llm) ──> EditPlan (strict schema)
                                      │
                    planner (remux vs re-encode, presets, warnings)
                                      │
                            builder ──> argv: list[str]
                                      │
                render_posix (shlex.join) — display/copy only
```

**Linux only.** fass is a Linux deployment — the Docker stack uses the
NVIDIA runtime for the GPU path — and **Windows and macOS are not
supported**: there is no build for them, and the install script
(`setup.sh`) refuses to run on anything but Linux. **Docker is required**
(CLI + compose plugin + a daemon reachable from your user), and the
machine needs **at least 2 GB of free RAM** — `setup.sh` checks both
before asking anything and aborts with a clear error if either is
missing.

## Quick start

This repo is the **public distribution tree**: everything runs from the
compiled CLI wheel in `wheel/` (CPython 3.12, Linux x86-64) or from the
published Docker image `boris271142/fass` (Docker Hub) — no Python
sources are needed.

### CLI (compiled wheel)

The host needs FFmpeg 9.x + ffprobe on PATH.

```bash
python3.12 -m venv ~/.venvs/fass
~/.venvs/fass/bin/pip install "wheel/fass-0.1.0-cp312-cp312-linux_x86_64.whl[api]"
                                                  # add ,storage for remote
                                                  # volume mapping
                                                  # (FTP/SFTP/SCP/S3),
                                                  # ,mcp for
                                                  # `fass mcp`

~/.venvs/fass/bin/fass "cut from 00:10 to 00:30 and resize to 720p" clip.mp4
~/.venvs/fass/bin/fass "replace the audio with song.mp3" clip.mp4 --asset song=song.mp3
./serve.sh                                       # web UI + JSON API on :8000
```

`./serve.sh` does the venv + wheel install itself if `~/.venvs/fass`
doesn't exist yet (override with `FASS_VENV`); it is idempotent — a
healthy server on the port is left running.

### Docker

`./setup.sh` — interactive one-time install (host folders, LLM endpoint,
http stream port, GPU pin); it pulls `boris271142/fass` and starts the
stack → http://127.0.0.1:8000. On a machine where an older fass install
already runs, it finds the old containers and asks: remove them and
upgrade, or quit — `./setup.sh --upgrade` answers "remove" up front
(only the containers go; the old config/media folders and images are
kept). A port held by a program that is not fass is never touched: the
http sidecar port can be moved (`--http-port`), the web UI port (8000)
is fixed. See [Docker deployment](#docker-deployment).

Every request returns one of four structured outcomes — `ready`,
`needs_clarification`, `unsupported`, `error`. Ambiguity is a first-class
answer, never a silent partial plan.

## No LLM required — the rules adapter

fass works fully **without any LLM** — no API key, no endpoint, no
network beyond the deployment itself. The adapter resolves as:
`rules` — always the deterministic parser; `llm` — the LLM only (an
error if no provider is configured); `auto` (the default everywhere —
CLI, API, UI) — **the LLM only when a provider is configured**
(Config tab or env vars), the rules otherwise.

What the rules are: a hand-written, deterministic parser — a curated
catalog of the phrasings fass supports (every feature in
[What it understands](#what-it-understands): trims, resizes, watermarks,
transcodes, GPU filters, combiners, quality comparisons, …), each
mapped onto the same strict, schema-bound edit plan the LLM would
produce. There is no model in the loop: the same instruction yields the
same plan, on every machine, every run, and the parser needs no
network. Ambiguity is still an explicit `needs_clarification`, never a
silent partial plan.

The LLM is an optional layer on top, not a dependency. Where it adds
value: tolerance for phrasings outside the rules' catalog, and a
post-build review of the generated command (fail-open — an unreachable
LLM never blocks a generation). Everything else — planner, argv
builder, validation gate — is deterministic either way: the model only
ever *plans*; it never writes shell.

## Web UI

`fass serve` (or the docker image) puts a single-page web UI at the
service's root — seven tabs, plus a footer (ffmpeg build, fass version,
[GitHub issues](https://github.com/suedenglehem/fass-cython/issues), and an
"if you're still clueless" video). The page is one self-contained HTML
file with no CDN dependencies (shaka-player is bundled locally for the
Player tab), so it works on a networked box as well as an isolated one.

### FFmpeg tab — generate

The workhorse: a natural-language request in, a validated command out.

- **Instruction** — the free-text request. When it reads like a quality
  comparison ("compare … with psnr/ssim/vmaf", "how much quality loss
  against …"), the other fields switch meaning: **Input** becomes the
  *reference*, **Output** the *distorted* clip — nothing is written, the
  score lands in the run log ([Quality comparison](#quality-comparison-vmaf--psnr--ssim)).
- **Input video** — a file from the input folder, or a stream URL. The
  field accepts several `-i file` tokens typed straight in: the first is
  the main input, the rest become extra inputs (auto-typed from their
  probes).
  - **`/input` and `/output` conventions** — how a name finds its file:
    a *bare* name (no `/`) resolves to the **input volume**
    (`$FASS_INPUT_DIR`, `/input` inside the container); when it is not
    there but exists in the **output volume**, it resolves there — the
    [comparison](#quality-comparison-vmaf--psnr--ssim) convention, a
    previous run's result (the distorted clip lives in `/output`). A
    relative name containing `/` is a *subfolder of the field's own
    volume* — `output/filename` typed here means
    `/input/output/filename` — tried against the input volume first,
    then the output volume (chained transcodes). An *absolute*
    `/input/<name>` or `/output/<name>` names a previous run's result
    by full path: accepted when the file exists, and remapped to the
    real volume when `FASS_INPUT_DIR` / `FASS_OUTPUT_DIR` point
    elsewhere than the literal `/input` / `/output`. Stream URLs and
    source specs pass through untouched, and the run log records every
    resolution as a note.
- **Output** — optional; a filename, or a stream URL to send to
  (`rtmp://`, `rtsp://`, `srt://`, `udp://`, …). The filename's
  **extension picks the output container** (`.mp4`, `.mkv`, `.ts`, …)
  when the instruction names none — an explicit container word in the
  instruction still wins, and a name that contradicts it (a `.mp4` name
  with "make it mkv") is an error. An **elementary-stream** name writes
  a raw dump: `.yuv` / `.rawvideo` / `.raw` → `-f rawvideo` (decoded
  frames, `yuv420p` on CPU; on a GPU deployment the decode runs on the
  card — `-hwaccel cuda -hwaccel_output_format cuda` +
  `hwdownload,format=nv12`), `.h264` / `.264` → `-f h264` (Annex-B),
  `.h265` / `.265` / `.hevc` → `-f hevc` (Annex-B — ffmpeg's raw HEVC
  muxer is named "hevc"). `.av1` is refused: no AV1 elementary-stream
  muxer exists in the build (its "av1" format is demux-only) — name a
  `.mkv`, `.mp4` or `.webm` and pick the av1 codec instead. The `?`
  tip — **`/input` and `/output` conventions** (mirroring the Input
  field): a bare name lands in the **output volume** (`$FASS_OUTPUT_DIR`,
  `/output` inside the container); a relative name containing `/` is a
  *subfolder of the output volume* — `input/filename` means
  `/output/input/filename`, created at run time (no existence check);
  the absolute `/input/<file>` is the one cross-volume destination — it
  writes into the **input** folder for chained processings, and the
  next command picks the file up by bare name (inside the container the
  path is literal; elsewhere it is remapped to `$FASS_INPUT_DIR`).
  Stream URLs (`rtmp://`, …) are never resolved, and `-` is the
  null-muxer diagnostic output (the run log notes it).
- **Watermark image** — a logo file; further logos go in as extra image
  inputs.
- **Adapter** — `auto` (the LLM only when a provider is configured and
  reachable — a configured-but-unreachable LLM falls back to the rules
  with a warning, never a dead end; an explicit `llm` with the LLM down
  is an error), `rules`, or `llm`.
- **Additional inputs** — one row per extra input: a file (or stream
  URL), a kind selector (`auto` / `video` / `audio` / `image` /
  `source`), and a remove button; **"+ add input"** appends the next
  `in1`, `in2`, … row.
- **Options** — *preflight* (validate the generated command against the
  **local FFmpeg build**, with an optional 1-second test run — see
  [Preflight](#preflight)), *verbose log* (`-loglevel verbose`;
  the log lands in the output folder's `log/`), and *serve over http*
  (write the output into the http sidecar tree so the **Player** tab can
  play it — HLS / DASH, m3u8 / mpd). *preflight* and *verbose log* are
  **recorded in the run record** when the run starts and **restored from
  the newest run at page boot** — they persist between runs and across
  restarts (server-side, so the state is the same on every client).
- **Generate** — runs the pipeline; the result pane renders per status:
  - **ready** (green) — an editable **Command** textarea with a copy
    button, the **argument array** (shell-safe JSON), **What it does**,
    **RAG evidence** (evidence-status and corpus badges, chunk links,
    warnings), **Defaults applied**, **Warnings**, and **Validation**
    (level + each check ok/FAIL). When execution is enabled on this
    deployment (`FASS_ALLOW_EXECUTE`), a **▶ Run now** button starts the
    command server-side — the textarea's *current* text is shlex-split
    and re-validated, so a hand edit is checked, not trusted — and jumps
    to the **Runs** tab. Otherwise the button is replaced by a note:
    copy the command and run it yourself.
  - **needs_clarification** (amber) — a "Please clarify" list; adjust
    the instruction and generate again.
  - **unsupported** (red) — "Not supported in the MVP", an optional
    **Second try (direct LLM)** section, and a "Supported instead" hint.
  - **error** (red) — the error list.
- **Save** — freezes the last *ready* generation as a preset (re-openable
  from Info / Log → Presets).
- **play2** — a live side-by-side comparison: the **Input** file on the
  left, the **Output** file on the right, encoded in real time and
  played in the **Player** tab
  ([play2](#play2--live-side-by-side-sbs-hls)). Enabled with bare
  filenames in both fields (the vmaf 1.0 gate); while the stream runs
  the button is **Stop** (danger) and stops the run.
- **Enter** — expert path, skips the NLU: prefills an editable
  `ffmpeg -i … -o …` skeleton from the input/output fields; **Generate**
  then validates it as a raw command.
- **Mediainfo** — ffprobe + mediainfo for the input (needs an input and
  an *empty* instruction); the result opens in Info / Log.
- **Batch mode** — a `*` in **Input video** turns Generate into a batch
  over every input file matching the pattern. The CLI equivalent is
  `--batch` ([CLI](#cli)).
  - **Input pattern** — fnmatch over bare filenames, case-sensitive
    (`*` is any run, so `*.ts` is every `.ts`). Local and remote input
    volumes both match; the pattern must be a bare name — no `/` (the
    input folder is flat, matched top level only).
  - **Output template** — `prefix*postfix`: exactly **one** `*`, and
    neither part may contain `/` (`.` is allowed, so
    `trancoded*.mov` is a valid template).
    - `*` → the input name **with its last extension cut**
      (`trancoded*.mov` over `clip.mkv` → `trancodedclip.mov`; a file
      with no extension is used as-is)
    - `@` (optional, in the prefix, the postfix, or both) → the
      input's **own extension, no dot** — so a pattern that spans
      extensions gets distinct outputs: `*_ttf_@.ts` over `titan*`
      (`titan.mp4` + `titan.ts`) → `titan_ttf_mp4.ts` and
      `titan_ttf_ts.ts`. Both tokens are inserted *verbatim*, so an
      `@` or `*` in a real filename is never mistaken for a token
      (a file with no extension makes `@` expand to nothing)
  - **Rejections** — `*` alone (prefix+postfix empty: the output would
    equal the input), and any template that expands to a matched
    input's own name (e.g. `*@`) — that would overwrite the input in
    place.
  - **Flow** — **Generate** builds the command for the *first* matched
    file first; only if it comes back ready does the confirmation modal
    appear — that generated command and the match *count* (the file
    list is never shown; it can be huge). Confirming runs the batch
    **directly**, with no second click; cancelling leaves the first
    file's command in the pane as a plain single file. The batch then
    runs every matched file **one by one** as a full fass run — each
    gets its own Runs-tab row and log, and, with a remote output volume
    mapped (Config tab), its upload there. The batch **stops at the
    first file that does not end `success`** (the stop is shown in the
    Runs tab). While the batch is armed, **Run now** re-runs it in
    order. **Clear**, the ✕ on the batch banner, or a fresh
    single-file generation disarms the batch; *Enter* and *Mediainfo*
    are disabled while a pattern stands in the Input field.
- **Clear** — resets the whole pane.

### Preflight

The **Validation** section of a ready result shows a *level* plus one
row per check (ok / FAIL):

- **`static`** — the default. The plan is validated against fass's own
  registry: every codec, container, operation, and filter in the
  command exists in the supported set.
- **`preflight`** — the plan was additionally checked against the
  **FFmpeg binary that is actually installed** on this deployment.
  Availability is build-specific — the same `-c libx264` or `-f webm`
  works in one build and not in another — so it is probed, never
  assumed. The build check runs automatically whenever the input file
  was probed (and a local ffmpeg exists), and always when the
  *preflight* option is checked. It reports:
  - **the build** — ffmpeg present, and its version;
  - **every encoder** the command will use — the video encoder (the
    NVENC coder for a GPU plan, the Quick Sync coder for a QSV plan;
    `-c copy` and raw dumps have no encoder to check), the audio
    encoder (no-audio containers like GIF have none — the plan
    emitted `-an`), and a soft-subtitle encoder when the container
    carries one;
  - **every filter** the command uses;
  - **the output muxer** — probed from the build's `-muxers` list;
  - **subtitle dumps** — that the input actually has a subtitle stream
    to dump.

With the *preflight* option checked, fass goes one step further and
executes a **1-second test run**: the generated command against the
local build with its output replaced by `-t 1 -f null -` (multi-pass
plans test the first pass; timeout 120 s). The test run is
**informative, never blocking** — a rejected command still comes back
*ready*; the verdict appears as a check row plus a warning ("preflight
test run (informative): …"), and the user who runs the command gets
the full error log. The CLI equivalent is `--preflight`
([CLI](#cli)); the API field is `preflight: true`
([HTTP API](#http-api)), and `GET /v1/env` lists exactly what the check
inspects.

### Files tab — the volumes

Input and output panes side by side (name / size / date, newest first),
each with the file count, the host folder the volume is mapped from, and
free / total disk. **Right-click a row**
for the context menu:

- **as input** (input pane) — copies the filename into the FFmpeg tab's
  Input field;
- **to input** (output pane) — copies the file into the input volume
  (the output original is kept) so it can become an input;
- **clipboard** (both panes) — copies the bare filename to the
  clipboard — paste it into the Info / Log tab's *File* field or
  anywhere else;
- **ffprobe** / **mediainfo** — opens the metadata in Info / Log;
- **tsanalyze** — TS containers only (`.ts` / `.mpg` / `.mpeg` / `.ps`);
  jumps to Info / Log and runs;
- **1st frame** — decodes the first frame to a JPEG (with dimensions) in
  a modal (Escape closes);
- **hls play** (both panes; video containers only — `.ts`, `.mp4`,
  `.mkv`, …) — starts an encode run straight into the **Player** tab:
  one video + one audio bitrate HLS (H.264 1080p50 CBR, AAC-LC
  128 k/48 kHz, 2 s segments, rolling window 5), written to
  `http/<name>/` with the playlist named after the source; `h264_nvenc`
  when the GPU is enabled, `libx264` otherwise. The video bitrate
  (default 3 000 kbps, 50–50 000) is the **hls** field in the Config
  tab. While the run is in flight the stream shows **live**; re-playing
  the finished stream from the Player tab re-encodes it.

### Runs tab — executed commands

The executed-command table (id, started, status, exit, command, output,
actions). On the header line, at the right margin: a **search field**
(filters the *command* column by keyword — case-insensitive, server-side
— mostly by input or output file name, but anything in the command
works; 250 ms debounce, and the 2.5 s auto-refresh keeps the filter in
place), a small **clear** button (removes the filter and shows the whole
list), and **↻ refresh**:

- status badges — **success** (green — with the total run time,
  `finished − started` wall clock, right under the word), **running**
  (amber; the table polls every 2.5 s while a run is in flight),
  **failed** (red);
- **output** — a link: http-served runs go to the **Player** tab,
  ordinary runs to the raw file;
- **log** — the run's log inline; **stop** — kills a running command.

### Player tab — play http-served output

Runs with *serve over http* land here as HLS / DASH playlists:

- **streams** table — playlist, kind, state (**live** / **vod**
  badges), size, modified, and a **play** row action; **↻ refresh**
  re-lists, and the list auto-polls while the tab is open, so a live
  stream keeps appearing as it is written;
- **play2** — the FFmpeg tab's play2 stream appears here at the fixed
  playlist `http/play2/stream.m3u8`, **live** while its run runs;
  stopping it here flips the FFmpeg tab's toggle back to play2
  ([play2](#play2--live-side-by-side-sbs-hls));
- playback uses the bundled **shaka-player** (v5.3.2, served from the
  app's own `/static/` — the page has no CDN dependencies): it plays
  both HLS and DASH from the `http/` tree, with a status line
  ("playing HLS (shaka-player) — …", or the fatal error). The play
  button doubles as stop (the player is destroyed before a re-load), and
  a browser without the media APIs shaka needs (MSE) gets a note
  instead of a dead player. A live playlist appears in the table the
  moment the muxer opens it — the UI waits for the first segment line
  before loading (a segment-less playlist fails with Shaka error
  1002), so the play2 stream auto-plays as soon as its first segment
  lands;
- **Purge stream tree** (danger, confirmed) — deletes everything under
  the output volume's `http/` tree.

### Info / Log tab — four views

A radio switch picks the view:

- **Media info** — Look in (input / output) + a bare filename:
  **Show media info** (ffprobe JSON), **TSAnalyze** (TS containers), and
  **Bitrate** (the vviz bitrate chart in a sandboxed iframe; non-mp4
  inputs are remuxed to mp4 first).
- **Run log** — pick a log from the server's list and **Show log**;
  logs longer than 10 000 lines show their last 1 000.
  **purge orphaned logs** (right of the row) deletes the logs whose
  source files are gone — every local `-i` input of the run missing, or
  the run record itself gone (lavfi/URL sources never count as
  orphaned); a confirm modal lists each candidate and its missing
  sources before anything is deleted, and the run records survive.
  Does nothing when the deployment has no logs.
- **Prompts** — the last 1 000 accepted instructions, latest first;
  click one to load it back into the FFmpeg tab's Instruction field.
- **Presets** — saved generations: one JSON file each, named by the md5
  of instruction + inputs + ffmpeg command (re-saving the same
  generation overwrites its file). Pick one, preview it, and **Load into
  the FFmpeg tab** restores the whole form plus the stored command.

### RAG tab — ask the documentation service

A direct query box for the retrieval service that backs the **RAG
evidence** on ready results. **Query** returns the matched chunks:
corpus, corpus-match and evidence-status badges, retrieval time,
warnings, and one card per chunk — title (linking into the pinned
manual), component type·name, option-name badges, score, and the chunk
text. The Config tab shows the service's status; a down service degrades
generation (fail-open), it never breaks it. In the published Docker
deployment the `fass-rag` sidecar is part of the stack (internal,
not port-published).

### Config tab — deployment settings

Sections, top to bottom:

- **Volumes — host folders ↔ container** — the host folders behind
  `/input`, `/output`, `/log`, `/scores`, each with an optional
  **remote mapping** (FTP / SFTP / SCP / S3 bucket —
  `ftplib`, paramiko, boto3; install the `[storage]` extra). At the
  right end of this header line is the **show more** ticker
  (persists per browser): while it is off, the tab's **advanced
  options** stay hidden — tick it on and they appear. The advanced
  options it gates are: the **remote mappings** below, the **min free
  disk space** and **output overwrite (`-y`)** rows, the LLM provider's
  **thinking modes**, and the whole **Streaming — port mappings**,
  **Shaka player**, **GPU (NVIDIA)** and **API key** sections. The
  mapping's role per volume:
  - **input** — a file missing locally is *downloaded from the remote
    before use*;
  - **output** — the result file, the verbose log and the run's `http/`
    subtree are *uploaded after a successful run*;
  - **log** — the run log + run record are *uploaded after every run*.

  Per mapping: type, host (S3: blank = real AWS), port (blank = default
  21/22/443), user (S3: access key id), password / secret, private key
  (SCP: paste the SSH *private* key — the server holds the public one;
  a password works as fallback), path or prefix, bucket, region, an
  *https* checkbox (http for an on-host MinIO / LocalStack), a *uuid
  naming* checkbox (S3 objects keyed by UUID, the real basename in
  object metadata), and a **test (unsaved values)** button. Under
  docker, on-host services are reached as `host.docker.internal`;
  sftp/scp host keys are not pinned (dev-tool convention). Below the
  volume rows: **min free disk space for output (GB)** (default 2,
  0 = no warning) — the UI polls the /output volume's free space every
  30 s; when it drops below the value a warning pops up and a banner
  stays in the tab ("⚠ /output low: X.XX GB free (min Y GB)"). The same
  banner also reports the LLM being down (it pings the endpoint every
  20 s). Below that: **output file already exists → overwrite it**
  (default off) — ticked, fass adds `-y` to a command that is missing
  it; off, an existing output file keeps the standard "output file
  already exists" warning.
- **LLM provider** — `anthropic` or any OpenAI-compatible endpoint
  (strata, vLLM, …): scheme (http for local servers, https for TLS
  end-user APIs — OpenAI, DeepSeek, …), host, port (https: blank = 443),
  api key (optional for the openai provider), model, timeout (1–300 s,
  default 90), and **thinking mode** — two independent tickers
  (an advanced option — visible with **show more** on;
  openai provider — Qwen3 / strata / vLLM): **ffmpeg cmd** (command
  generation + validation) and **rag** (the LLM answer on the RAG tab).
  Both **off by default** — for the structured output the reasoning
  trace is pure overhead (and can exhaust max_tokens); endpoints that
  reject the chat-template kwarg fall back to a plain request
  automatically. Setting or switching the model runs a capability
  probe: a model without thinking gets both tickers permanently
  disabled (until the model is switched again); undetected leaves them
  enabled. **Test LLM (unsaved values)** reports "ok — model X answered
  in Ns: '…'" and re-runs the probe.
- **Streaming — port mappings (host port ↔ container port)** (an
  advanced option — visible with **show more** on) — the
  host-address rewrite for stream URLs: *the host in a URL → the docker
  host* (udp/rtp inputs bind 0.0.0.0 inside the container), the host
  address (docker bridge gateway, default 172.17.0.1), and per-port
  rows (label, container port, host port, proto) with
  **"+ add port mapping"**. Right of the section title: a **multicast**
  indicator — green **multicast enabled** / red **multicast disabled**
  — the startup check (once per process, cached; also in `GET /v1/env`
  and the container log) of whether any container interface carries
  the MULTICAST flag (`ip link show` over every interface). It tells
  you the *kernel side* is multicast-capable — the prerequisite for
  receiving a multicast group source (`udp://239.x.x.x:port`) at all.
  Linux sets the flag by default, so it stays green in bridge mode too;
  what makes the host's groups actually reachable is host network mode
  + the host firewall — see [Multicast input/output](#docker-deployment).
- **Shaka player** (an advanced option — visible with **show more**
  on) — the settings of the Player tab's player
  (shaka-player, bundled locally — the page has no CDN dependencies).
  One row: **bitrate play file** (50–50 000 kbps, default 3 000 = the
  3M reference) — the video bitrate of the Files tab's **hls play**
  single-bitrate stream (H.264 1080p50 + AAC-LC 128 k; the segment
  bufsize is auto 2×); **bitrate play2 (kbps)** (default 5 000 = the
  5M reference) — the video bitrate of the FFmpeg tab's **play2**
  side-by-side live HLS encoding (CBR, the buffer is auto 2×);
  **stream retention — days to keep** (default 1) — the hourly sweep
  deletes Player-tab stream dirs whose newest file is older than this
  many days, 0 = keep forever. Second row — **Encryption** (VOD only):
  **aes-128 key** (32 hex chars, empty = off) — VOD HLS encodes come
  out AES-128 encrypted (mpegts segments; players and ffmpeg fetch the
  key via the EXT-X-KEY URI the app serves at `/keys/encryption.key`,
  so encrypted HLS plays in the Player tab); **dash key** + **dash kid
  (key id)** (32 hex each, both needed) — VOD DASH encodes come out
  CENC AES-CTR encrypted (decrypting an encrypted DASH input:
  reassemble the fragmented mp4 from the init + chunk segments and read
  it with `-decryption_key` + this key before -i — this build's dash
  format is mux-only; the MPD carries no pssh, so encrypted DASH is not
  playable in the browser).
- **GPU (NVIDIA)** (an advanced option — visible with **show more**
  on) — enable nvenc (H.265, and AV1 when the GPU can
  encode it — H.264 stays on libx264). *Which* GPU ffmpeg uses is a
  deployment concern, pinned in the compose file with
  `CUDA_VISIBLE_DEVICES` — the container always gets **all** host GPUs,
  because a single-GPU presentation breaks NVENC
  (`OpenEncodeSessionEx failed: unsupported device (2)`). Card support:
  NVIDIA **Turing (sm_75) through Blackwell (sm_120)** — the full
  generation list is in [Docker deployment](#docker-deployment).
- **RAG — documentation retrieval** — the service status: url, timeout,
  top_k, max evidence chars, the configured corpus, whether the
  instruction is sent into the query, and which corpora are loaded — or
  "RAG disabled" / "service unreachable (fail-open)". (The LLM answer
  appended to a RAG-tab search has its own **rag** thinking ticker —
  see LLM provider.)
- **API key** (an advanced option — visible with **show more** on) —
  the control API's two switches (see
  [HTTP API](#http-api)): the **API/MCP** ticker (to the left of the key
  field) is the **master switch** for the whole control API *and* the
  `fass mcp` server — off, every `/v1/*` call answers **404** (the API
  looks unmapped, not locked, for anything scanning it), `fass mcp`
  refuses to start, and since the web UI itself runs on the API it stops
  working too; the page, `/static`, `/media`, `/keys` and `/healthz`
  routes stay open, and a banner explains how to get back: set
  `"api_mcp_enabled": true` in the config file on the server — the API
  is the only writer, so with it off even `PUT /v1/config` is 404 and
  the switch cannot re-enable itself. On by default (a config file
  without the field behaves as on). With the switch on, the
  **enable api key** ticker + **fass api key** field (at least 16
  characters when enabled) additionally require
  `Authorization: Bearer <key>` on every `/v1/*` call — anything else
  gets 401. The web page itself stays open (it is content serving for
  the player, not the control API): it keeps the key in the browser,
  sends it automatically with every API call, and pops a key-entry
  banner at the top when a 401 comes back. The key follows the LLM API
  key precedent — returned clear by `GET /v1/config`, masked by the UI —
  and the config is re-read per request, so toggling takes effect
  immediately, no Apply. Key ticker off (or a blank key) = the API
  stays open, exactly as before.
- **Appearance** — theme (auto / light / dark "night" / kitty "pink" /
  autodesk "gray") and content width (default 1260 px / narrower
  860 px); remembered per browser.
- **Deploy** (docker deployments) — the docker-control + fass-worker
  sidecar status; **Save** (LLM, stream addresses and the compose
  preview are live immediately; volumes / ports / GPU take effect after
  Apply) — a changed input/output/log folder that does not exist on the
  host is rejected (the config file stays untouched and the form is
  reverted to the saved values), and a successful save pops a
  confirmation naming what is live vs what still waits for Apply;
  **Test all** — runs the same checks against the *current form
  values* (what a Save would store), one line per check: the LLM
  (against the unsaved block — "ok — model X answered in Ns", or
  "not configured — skipped"), each remote mapping of input / output /
  log (a `none` block reports "none configured — skipped"), and the
  GPU (only when the form checkbox is enabled — else
  "disabled — skipped"); unconfigured / disabled items are reported as
  *skipped*, not failed;
  **Apply to container** (danger — asks the sidecar to recreate
  the container from the saved config; the connection drop is expected,
  the UI polls the apply result, and a swap that fails partway
  re-creates the old container); and the **generated compose** (what
  Apply will create). At startup, a configured folder that is missing
  on the host raises an error banner and switches the user to this tab.
- **Process control** (the tab's very bottom, every deployment) —
  **⏻ Stop ffmpeg processes** (danger, no confirmation,
  `POST /v1/ffmpeg/stop-all`) — the emergency stop: kills every ffmpeg
  fass launched (FFmpeg-tab runs + vmaf scoring) and every stray
  ffmpeg process. The per-run stop is narrower: the Runs tab / a stream
  row stops ONE run — SIGTERM its exact process group, SIGKILL after
  ~5 s if it survives. Beside the button: **ffmpeg process max time
  (seconds)** (default 21 600 = 6 h, 0 = unlimited) — the hard wall
  time for ONE fass-launched ffmpeg process (a run attempt or one VMAF
  chain attempt); a process still printing output is never killed
  early — only a 3-minute silence (VMAF) counts as a stall.
  `FASS_VMAF_TIMEOUT` overrides this for VMAF only.

## CLI

Subcommands (the bare form is `generate`):

```bash
fass "INSTRUCTION" [input] [options]        # generate (the default)
fass probe FILE                             # ffprobe JSON for one file
fass env                                    # this FFmpeg build vs the registry
fass serve [--host 0.0.0.0] [--port 8000]   # web UI + JSON API
fass worker [--host 0.0.0.0] [--port 8001]  # fass-worker sidecar (Apply)
fass mcp [--transport stdio|streamable-http] [--host 127.0.0.1] [--port 8765]
fass feedback --useful | --incorrect [--category C] [--note S]
         [--error "ffmpeg error you saw"] [--instruction S --consent]
fass examples                               # supported-feature summary + examples
```

`generate` flags:

- **instruction**, **input** (positional) — the request and the main
  input (a file from the input folder, or a stream URL)
- **-o / --output** — output filename, or a stream URL to send to
  (`rtmp://`, `rtmps://`, `rtsp://`, `rtsps://`, `srt://`, `udp://`,
  `rtp://`, `tcp://`)
- **--watermark IMAGE** — a logo to burn in
- **--asset id=path** or **--asset id=kind:path** (repeatable; kind
  `video` | `audio` | `image` | `source`) — extra typed inputs
- **--adapter {auto,rules,llm}** — default `auto` (the LLM only when a
  provider is configured, the rules otherwise — see [No LLM
  required](#no-llm-required--the-rules-adapter))
- **--previous PLAN.json** — revision: only what the new instruction
  changes changes
- **--metadata FILE** — pre-collected ffprobe JSON for the input (skip
  the probe)
- **--preflight** — check the local FFmpeg build before planning
- **--json** — print the full JSON response (always on with `--case`)
- **--execute** — run the generated command locally (the CLI gate; in the
  docker deployment execution happens from the **Runs** tab)
- **--batch FILE|DIR …** — batch: the *same* instruction over many
  files, one at a time in sorted order. A directory contributes its
  top-level video files only (the registry's video containers — no
  recursion); an explicit file is taken exactly as given (a missing
  name is reported as a failure, not dropped). Validate-only unless
  **--execute**; a file the pipeline rejects or that exits non-zero is
  reported and **skipped** — the loop always continues. Ends with a
  per-file table (filename, status, exit code, output or error
  snippet); the process exits 0 only when every file succeeded.
  **--batch-out DIR** — every result is written into DIR under the
  input's own name; without it each file keeps its plan's default
  output name. One-file flags (`input`, `-o`, `--previous`,
  `--metadata`) are rejected in batch mode; shared assets
  (`--watermark` / `--asset`) apply to every file. The web-UI
  equivalent is a `*` in the Input field
  ([Batch mode](#ffmpeg-tab--generate))
- **--case FILE** — a whole test case in one JSON file:
  `{"instruction", "assets": {"main": file, …}, "assets_dir"?,
  "output"?, "adapter"?, "execute"?}` — asset paths are relative to
  `assets_dir` (default: the case file's directory); implies `--json`
- **--version**

## HTTP API

`fass serve` is a JSON API (FastAPI) at `http://<host>:8000`, and the
web UI is just one of its clients — every tab feature works with curl.
Every domain outcome is a structured **200** with a
`status` — `ready`, `needs_clarification`, `unsupported`, `error`
(`cancelled` when an in-flight generation is aborted); 4xx is reserved
for malformed requests. There is **no authentication by default** —
anyone who can reach port 8000 can generate commands, execute them and
rewrite the deployment config — but the Config tab's **API key**
section (before Appearance) carries two switches: the **API/MCP**
master ticker — off, every `/v1/*` call answers 404 (API-absent: the
API looks unmapped, not locked) and `fass mcp` refuses to start — and
the **enable api key** ticker — on, every `/v1/*` call must carry
`Authorization: Bearer <key>` (the key is at least 16 characters) or
gets 401, while the page, `/static`, `/media` and `/keys` routes stay
open for the player. Either way, run fass on a trusted network or
behind an authenticating proxy. Execution itself stays off without
`FASS_ALLOW_EXECUTE=1` (the docker image sets it).

The five most-used groups are below; the **complete endpoint
reference** — all routes, request fields, responses and curl examples —
is in [API.md](API.md).

**1 · Generate** — `POST /v1/commands` plans the edit. On `ready`,
`arguments` is the argv array and `command` its POSIX rendering — the
same JSON the CLI prints with `--json`:

```bash
curl -s http://127.0.0.1:8000/v1/commands \
  -H 'content-type: application/json' -d '{
    "instruction": "resize to 1280x720 using the gpu",
    "assets": {"main": "10_input1.ts"},
    "output_filename": "gpu_720p.mp4",
    "adapter": "rules"
  }'
# → {"status": "ready",
#    "arguments": ["ffmpeg", "-y", "-hide_banner", "-loglevel", "info",
#                  "-i", "/input/10_input1.ts",
#                  "-vf", "format=yuv420p,hwupload_cuda,scale_cuda=w=1280:h=720,hwdownload,format=yuv420p",
#                  "-map", "0:v:0", "-map", "0:a?",
#                  "-c:v", "libx264", "-crf", "23", "-pix_fmt", "yuv420p",
#                  "-c:a", "libfdk_aac", "-b:a", "160k", "-movflags", "+faststart",
#                  "/output/gpu_720p.mp4"],
#    "command": "ffmpeg -y -hide_banner … gpu_720p.mp4",
#    "plan": {…}, "summary": […], "defaults": […], "warnings": […]}
```

`assets` is a **map of id → path/URL** and must include `main` (the
input video); extra ids bind further inputs (a value may be
`"kind:path"` to pin the kind). `target_shell` takes only `"posix"` —
the rendering is derived from argv, never parsed back. `preflight:
true` checks the local FFmpeg build before planning; `generation_id`
makes an in-flight generation cancellable (`POST /v1/commands/cancel`);
`previous_plan` revises an existing plan.

**2 · Execute** — `POST /v1/runs` runs the ready argv — on deployments
with execution enabled only (the docker image sets it; elsewhere 403).
Post the **array**, never a shell string; a multi-pass plan posts
`steps` (each pass's argv, final pass last), `serve_http: true`
http-serves a generated HLS playlist for the Player tab:

```bash
curl -s http://127.0.0.1:8000/v1/runs \
  -H 'content-type: application/json' -d '{
    "arguments": [ …the ready response's "arguments"… ],
    "instruction": "resize to 1280x720 using the gpu"
  }'
# → {"run": {"id": "…", "status": "running",
#            "output": "…", "http": false, …}}
```

`GET /v1/runs/{id}` polls the run, `GET /v1/runs/{id}/log` its log,
`POST /v1/runs/{id}/stop` stops it.

**3 · List player streams** — `GET /v1/streams` — the HLS / DASH
playlists currently served from the output volume's `http/` tree
(`serve_http` runs, the Files tab's hls play), each with a playable
`url`:

```bash
curl -s http://127.0.0.1:8000/v1/streams
# → {"streams": [{"name": "titan.m3u8", "kind": "hls",
#                 "path": "http/shotrun/titan.m3u8",
#                 "url": "http://127.0.0.1:3011/http/shotrun/titan.m3u8",
#                 "size": 244, "live": false, …}],
#    "http_base_url": "http://127.0.0.1:3011",
#    "total_size": 1138584, "file_count": 6}
```

**4 · Build info** — `GET /v1/env` — the FFmpeg build fass validates
against: fass version, build info, registry version, and the presence
of every encoder, filter and bitstream filter the registry references
— what a `preflight: true` generation checks:

```bash
curl -s http://127.0.0.1:8000/v1/env
# → {"available": true, "version": "v1.618033.738dce2",
#    "registry_version": "2.12.0",
#    "encoders": {"video:libx264": {"encoder": "libx264", "present": true}, …},
#    "filters": {"scale_cuda": {"present": true}, …}, …}
```

**5 · Pointwise VMAF scoring** — `POST /v1/vmaf` scores `distorted`
against `reference` frame by frame — the FFmpeg tab's "vmaf 1.0" button
as an API. Both fields are **bare filenames** resolved against the
volumes (reference: input → output; distorted: output → input); the
reference is the ground truth. Probing picks the filter chain
automatically — an 8-branch matrix over interlace × size (yadif
deinterlace on whichever side is interlaced, distorted scaled to the
reference's size, fps matched) — and `mode` routes the compute:
`"auto"` (default: GPU first, CPU fallback), `"cpu"` or `"gpu"`
(pinned; a pinned `gpu` with no GPU is a 502). Durations are
independent: with a >1 s difference the first call answers **409** with
the advisory and scoring over the shorter file proceeds only after a
re-post with `"confirm": true` (the run itself always uses
`eof_action=pass`):

```bash
curl -s http://127.0.0.1:8000/v1/vmaf \
  -H 'content-type: application/json' -d '{
    "reference": "input.mp4",
    "distorted": "dist_720p.mp4"
  }'
# → 409 {"detail": "dist_720p.mp4 is 8.0 s, input.mp4 10.0 s — VMAF
#     would be computed over the shorter file (8.0 s). Confirm to
#     continue."}
curl -s http://127.0.0.1:8000/v1/vmaf \
  -H 'content-type: application/json' -d '{
    "reference": "input.mp4",
    "distorted": "dist_720p.mp4",
    "mode": "auto",
    "confirm": true
  }'
# → {"status": "ok",
#    "id": "8f2c1ab0-…", "score_file": "8f2c1ab0-….json",
#    "reference": "input.mp4", "distorted": "dist_720p.mp4",
#    "mode": "gpu", "gpu_path": "full",
#    "branch": "c2",
#    "branch_label": "reference progressive, distorted progressive, different sizes",
#    "model": "vmaf_v0.6.1",
#    "steps": ["reference: input.mp4 — unchanged (progressive, 1920x1080, 30fps)",
#              "distorted: dist_720p.mp4 — resized 1280x720 -> 1920x1080 (bicubic)",
#              "duration: computed over the shorter file (8.0 s of 10.0 s)",
#              "path: GPU full (scale_cuda on NVIDIA GeForce RTX 3080 Ti, libvmaf on CPU)",
#              "model: vmaf_v0.6.1 — 1080p-calibrated"],
#    "command": "ffmpeg -hwaccel cuda -hwaccel_output_format cuda \
#      -i /input/dist_720p.mp4 -i /input/input.mp4 \
#      -filter_complex '[0:v]scale_cuda=1920:1080:interp_algo=bicubic:format=yuv420p,hwdownload,setpts=PTS-STARTPTS[dd];[1:v]setpts=PTS-STARTPTS[rd];[dd][rd]libvmaf=model=…:log_fmt=json:log_path=…:eof_action=pass' \
#      -f null -",
#    "durations": {"reference": 10.0, "distorted": 8.0},
#    "frames": 240,
#    "pooled": {"mean": 87.93, "min": 52.1, "max": 99.4,
#               "harmonic_mean": 84.2},
#    "elapsed": 18.4,
#    "json": {"model": "…", "frames": [{"frame_num": 0, "vmaf": 87.91}, …]}}
```

**The same request on CPU and on GPU** — pin `mode` to see exactly where
the compute goes:

```bash
# CPU — decode, scaling/deinterlace and the VMAF computation all on the CPU
curl -s http://127.0.0.1:8000/v1/vmaf \
  -H 'content-type: application/json' -d '{
    "reference": "input.mp4",
    "distorted": "dist_720p.mp4",
    "mode": "cpu"
  }'
# → … "mode": "cpu", "gpu_path": "none",
#    "steps": […, "path: CPU (all filters + libvmaf on CPU)", …],
#    "command": "ffmpeg -i /output/dist_720p.mp4 -i /input/input.mp4 \
#      -filter_complex '[0:v]scale=1920:1080:flags=bicubic,setpts=PTS-STARTPTS[dd];[1:v]setpts=PTS-STARTPTS[rd];[dd][rd]libvmaf=model=version=vmaf_v0.6.1:log_fmt=json:log_path=…:eof_action=pass' \
#      -f null -"

# GPU — decode on the GPU; on a build with libvmaf_cuda (the CUDA libvmaf
# rebuild) the VMAF computation itself runs on the GPU too
curl -s http://127.0.0.1:8000/v1/vmaf \
  -H 'content-type: application/json' -d '{
    "reference": "input.mp4",
    "distorted": "dist_720p.mp4",
    "mode": "gpu"
  }'
# → … "mode": "gpu", "gpu_path": "score",
#    "steps": […, "path: GPU score (decode, scaling and the VMAF computation
#       itself on NVIDIA GeForce RTX 3080 Ti — libvmaf_cuda)", …],
#    "command": "ffmpeg -hwaccel cuda -hwaccel_output_format cuda \
#      -i /output/dist_720p.mp4 -hwaccel cuda -hwaccel_output_format cuda \
#      -i /input/input.mp4 \
#      -filter_complex '[0:v]scale_cuda=1920:1080:interp_algo=bicubic:format=yuv420p,setpts=PTS-STARTPTS[dd];[1:v]scale_cuda=1920:1080:interp_algo=bicubic:format=yuv420p,setpts=PTS-STARTPTS[rd];[dd][rd]libvmaf_cuda=model=version=vmaf_v0.6.1:log_fmt=json:log_path=…:eof_action=pass' \
#      -f null -"
```

- **`gpu_path`** — which stage produced the score: `"score"` (the whole
  chain on the GPU — decode, scaling and the VMAF computation itself;
  needs a build with the `libvmaf_cuda` filter and no fps resample — by
  far the fastest on long files), `"full"` (GPU decode +
  scale/deinterlace, then `hwdownload` and libvmaf on the CPU),
  `"decode_accel"` (GPU decode only, all filters on the CPU) or `"none"`
  on a CPU run.
- **Persistent "vmaf on gpu"** — the Config tab's GPU (NVIDIA) section
  has a *vmaf on gpu* option (persisted in `config.json`). When it is
  on, `mode: "auto"` jobs route to the GPU-scoring chain — as if
  `"mode": "gpu"` had been sent; an explicit `"cpu"` or `"gpu"` always
  passes through unchanged. Without the `libvmaf_cuda` filter the jobs
  take the previous GPU paths and say so in `steps`.

- **Transparency** — `command` is the exact ffmpeg command that produced
  the score and `steps` names every extra step taken (which file was
  deinterlaced, what was resized to what, the fps resample, the duration
  truncation, GPU vs CPU and which card, the model). Scoring is a
  sensitive domain — the response never lets a number stand without its
  provenance.
- **The score is kept** — the libvmaf JSON document is stored in the
  scores volume (Config → Volumes → `/scores`) as `<uuid4>.json`, and
  `<timestamp> <uuid> <reference> <distorted>` is appended to
  `master.txt`; the scores remote mapping (SMB/S3/WebDAV) receives both
  files after every score, best-effort.
- **The model is picked automatically** — the reference's height chooses
  the scoring model: anything taller than 1440p (i.e. 4K/2160p references
  and up) automatically gets the 4K-calibrated `vmaf_4k_v0.6.1`,
  everything at or below 1440p the 1080p-calibrated `vmaf_v0.6.1`. The
  choice is reported in `model` and in `steps` (`"model: …
  (4K-calibrated)"`). The 4K model must be loadable in the build —
  `FASS_VMAF_MODEL_4K` (a full path), a `vmaf_4k_v0.6.1.pkl`/`.json` in
  `FASS_VMAF_MODEL_DIR`, or the libvmaf built-in registry — and the
  static image build doesn't bundle it, so a taller-than-1440p reference
  is a 400 until the model file is provided.
- **>4K reference** — the reference above 3840 px triggers a second
  409 proposing to score at 4K-fit dimensions with the 4K model
  (`vmaf_4k_v0.6.1`, when the image ships it); without the 4K model the
  same request is a plain 400 ("scale the input to 4K first").
- **Errors** — 400 bare-name/format problems, 404 file not in either
  volume, 502 probe or ffmpeg failure (a pinned `gpu` with no card
  names the missing GPU), 503 the output volume not mounted.

The complete endpoint reference (all 53 routes, request fields,
responses and curl examples) is in [API.md](API.md).

## MCP — fass as a tool for agents

`fass mcp` speaks the Model Context Protocol, so any MCP client (Claude
Code, an agent, a test harness) can drive fass directly. stdio by
default (the client spawns the process); `--transport streamable-http`
exposes a network endpoint on host:port. Install the extra (in the
venv): `pip install "wheel/fass-0.1.0-cp312-cp312-linux_x86_64.whl[mcp]"`
(mcp v1 — 2.x renamed FastMCP).

Four tools, all returning the same JSON the CLI's `--json` prints:

- **generate**(instruction, assets, output?, adapter?) — `assets` maps
  ids to file paths (`main` required; `watermark` for a logo image; free
  ids like `in1` / `in2` for extras); a value may be `kind:path`
  (video / audio / image / source) to pin the kind
- **run_case**(case_path) — a case described entirely by a JSON file
  (the `--case` schema); with `"execute": true` the ready command(s)
  also run and the return code is recorded as `execute_rc`
- **probe**(file) — ffprobe metadata: streams, codecs, duration,
  resolution
- **env_info**() — the local FFmpeg build fass validates against:
  version, registry version, and the presence of every encoder/filter
  the registry references

Bare filenames resolve against `$FASS_INPUT_DIR` / `$FASS_OUTPUT_DIR`
exactly like the rest of fass, so a harness that stages a case's media
into its input dir can reference the files by their original names.

## What it understands

**Shape**: N typed inputs — video, audio, image, local capture sources
(the web UI has a "+ add input" row for each — or several `-i file` tokens
typed straight into the main input field) → one output that is a file
**or** a stream destination. Multiple inputs is what makes "replace the
audio with song.mp3" and "watermark it with a and b" work.

- **Trim / cut** (frame-accurate), **resize** (aspect-preserving, exact
  dims, letterbox), **grayscale**, **crop** (center), **rotate** (quarter
  turns), **speed** (0.25–8×, video and audio together)
- **Filter effects** — brightness / contrast / saturation (`eq`), fade in /
  out (video and audio), blur & sharpen, **burned-in text or a live
  timecode** (`drawtext`), volume / loudness normalization, low- / high-pass,
  bass & treble, echo, limiter, delay, silence padding
- **Transform filters** — audio dynamics (`acompressor`, `compand`,
  `dynaudnorm`, `adrc`, `adynamicequalizer`, `adeclick`, `silenceremove`,
  `hdcd`), video cleanup (`yadif` deinterlace, `decimate` duplicate-frame
  drop, `chromakey`, `drawbox`, arbitrary-angle `rotate`), frame-rate
  (`fps`/`framerate`), color space (`colorspace`/`colormatrix`), aspect
  ratio (`setdar`/`setsar`) — every chain validated against the filter
  registry, with semantic-trap warnings (asetrate changes pitch **and**
  speed; decimate drops frames; colorspace is metadata-only, …)
- **Diagnostic analysis** — "detect silences", "how loud is this", "detect
  black frames", "where are the black bars", "detect interlacing", "detect
  frozen frames", "audio statistics", "frame info", "bounding box"
  (`silencedetect`, `volumedetect`, `astats`, `ashowinfo`, `blackdetect`,
  `cropdetect`, `freezedetect`, `idet`, `showinfo`, `bbox`) — an
  all-diagnostic plan decodes through the filters and discards the stream
  (`-f null -`, no output file), raising the log level to info so the
  results land in the run log
- **Combiners** — two typed inputs through a labeled filter graph:
  `crossfade a.mp4 and b.mp4` (xfade; offset computed from the first
  input's duration, a "2-second crossfade" sets the transition duration;
  "crossfade the audio" → acrossfade), `stack them side by side /
  vertically` (hstack / vstack), `concatenate a.mp4 and b.mp4` (concat;
  "without the audio" drops it), `mix the audio` (amix), `merge the
  audio tracks` (amerge), `join the audio to 5.1` (join), "join / merge
  the two videos" = end-to-end
- **Quality comparison** — `compare a.mp4 against b.mp4 with psnr`
  (also ssim; libvmaf on builds that ship the filter + model): the
  reference clip is the **first** input (`-i ref -i main`), the metric
  runs frame by frame, the summary lands in the run log (null muxer —
  nothing is written) — full workflow:
  [Quality comparison](#quality-comparison-vmaf--psnr--ssim)
- **Two-pass stabilization** — `stabilize the shaky clip`: a
  vidstabdetect pass measures the shake into a `.trf` next to the
  output, the final pass applies vidstabtransform — the response
  carries the plan's `steps` and the execution layer runs them in order
- **Double-pass encoding** — fass runs at most TWO ffmpeg passes, never
  more (a "triple pass" / "3-pass encode" request is refused as
  unsupported). The plan model produces two native shapes: the
  **two-pass vidstab** plan above, and a **two-pass H.264 CPU encode**
  (`double pass h264, about 100 MB` / `two pass, video bitrate 5M`) —
  pass 1 writes x264 stats, pass 2 does the final encode; H.264 on the
  CPU only (never GPU/QSV, never an ABR ladder), allowed only when the
  request also names a size target or a video bitrate, and VOD only
  (a file or VOD hls/dash output — never a live or stream destination).
  Both run as ONE job and the execution layer collates the two passes'
  logs into a single run. For encoders the plan model does not
  double-pass — **x265 / nvenc / AV1** — the image ships user-facing
  scripts under `/opt/multistaged/` (`twopass_x265.sh`,
  `twopass_nvenc.sh`, `twopass_av1.sh`, and a `vidstab.sh` wrapper;
  VOD-only, exactly two stages, see `/opt/multistaged/README.md` for
  usage). Note: 9.0.2's `hevc_nvenc` has no `-pass`, so the nvenc
  script is a SINGLE invocation with `-multipass qres`
  (quarter-resolution analysis) rather than two.
- **Encrypted VOD output** — HLS **AES-128** and DASH **CENC AES-CTR**,
  keyed from the Config tab's "Shaka player" section (VOD only):
  - **HLS AES-128** — the `aes-128 key` field (32 hex chars) is written
    at app start and on every config save to `/keys/encryption.key`
    (16 binary bytes) and `/keys/keyinfo.txt` (line 1 = the key URI,
    line 2 = the file path); the VOD HLS encode then uses
    `-hls_key_info_file /keys/keyinfo.txt`, so the playlist's
    `EXT-X-KEY` URI points at the app's own `/keys` route and a player
    fetches and decrypts transparently — the 9.0.2 muxer writes ONE
    `EXT-X-KEY` with a constant all-zero IV for the whole playlist,
    which both ffmpeg and Shaka read back fine. **AES-128 with mpegts
    segments only** — SAMPLE-AES and fragmented-mp4 encryption are
    refused, and an explicit "plain / unencrypted hls" omits the key
    for that one encode. Decoding an encrypted HLS *input* (an m3u8
    whose `EXT-X-KEY` URI is http) takes `-protocol_whitelist
    file,crypto,data,http,tcp` before `-i` (the muxer opens key files
    with a restricted whitelist) — on the FFmpeg tab's direct-command
    path (the plan model does not express input-side options).
  - **DASH CENC** — the `dash key` + `dash kid` fields (32 hex each)
    become `-format_options
    "encryption_scheme=cenc-aes-ctr:encryption_key=…:encryption_kid=…"`,
    which the dash muxer forwards to the fmp4 segment muxer — the media
    is fully encrypted (the init segment carries the `sinf` → `tenc`
    protection boxes with `default_isProtected=1`) and round-trips with
    the key. Decoding: this build's `dash` format is MUX-ONLY (no DASH
    demuxer) and 9.0.2 renamed the key option — reassemble the
    fragmented mp4 (init segment + its chunk `.m4s` files concatenated)
    and read it with the BMFF demuxer's `-decryption_key <32 hex>`
    before `-i` (direct-command path; the old `-cenc_decryption_key`
    no longer exists). Known 9.0.2 upstream limitation: the MPD
    carries no ContentProtection / `default_KID` / pssh box, so a
    player that needs them to pick the key will not find them in the
    manifest — the media still decrypts with the key.
- **Interlaced output** — `transcode to mpegts h264 3Mbps 1080p interlaced
  tff` (also `bff`, "top field first", "bottom frame first"): the scaling
  runs first, then `tinterlace=interleave_top|bottom` merges consecutive
  progressive frames into interlaced ones (an already-interlaced source is
  only re-signaled) and `setparams=field_mode=tff|bff` + `-flags
  +ilme+ildct` make the encoder encode and signal the field order. Only
  MPEG-2 (mpegts), ProRes and H.264 output can carry it — H.265 / AV1 /
  VVC / VP9 / VP8, hardware (nvenc / QSV) encoding, stream copy, a
  multi-bitrate ladder and audio-only output are refused; a missing or
  contradictory field order is a clarification
- **Container conversion** — a broad, codec-matrix-validated set: video in
  MP4 / MOV / MKV / WebM / MPEG-TS / MXF / AVI / FLV / GIF / WebP / OGV with
  H.264 / H.265 / AV1 (libaom, the default) / SVT-AV1 / VP9 / VP8 / Theora /
  VVC / MPEG-2 / ProRes / MJPEG, audio in MP3 / AAC / FLAC / Opus /
  ALAC / AC-3 / E-AC-3 / PCM, HLS, and more. The default AAC encoder is
  `libfdk_aac` (better quality per bitrate) — the built-in `aac` stays
  only on an explicit native-AAC request, and a plan encoding fdk on a
  build without `libfdk_aac` falls back to the built-in with a warning.
  When the probes show the input
  streams already match, it **remuxes** (`-c copy`) instead of re-encoding —
  with bitstream filters in **both directions**: Annex-B restamp
  (`h264_mp4toannexb` / `hevc_mp4toannexb`) for mp4/mov → MPEG-TS, ADTS strip
  (`aac_adtstoasc`) for MPEG-TS → mp4/mov. Remuxes also accept **named
  bitstream filters** with validated options (`h264_metadata level=4.1`,
  `setts`, `filter_units`, `trace_headers`, `showinfo` (FFmpeg 7.1+), …) —
  any of them on top of the automatic ones; "trim" in a copy context is a
  stream-copy cut (`-ss`/`-t` with `-c copy`)
- **Encoding options** — target bitrate (`cbr 10 Mbps`, or per stream:
  `video h265 3Mbps … audio aac 128kbps` → `-b:v 3000k -maxrate 3000k
  -bufsize 6000k` + `-b:a 128k`), **GOP** (`gop 50` / "a gop of 50" →
  `-g 50`), pixel format (8-bit / 10-bit / 4:4:4), H.264 profile &
  preset, audio resampling (sample rate / channels), and **per-encoder
  options**: NVENC / QSV rate control,
  ProRes profile, x264 / x265 / VVC tuning, encoder-specific flags — plus
  **GPU encoding** (nvenc) when a deployment exposes a GPU. On a GPU
  deployment the encoder choice is a **deployment default**, not only an
  explicit ask: a plain `re-encode as h265` lands on `hevc_nvenc` (AV1
  on `av1_nvenc` when the GPU can encode it) with a note in the
  explanation; `no gpu` (or `on cpu`, `cpu encode`, …) in the
  instruction keeps the CPU encoder. H.264 stays on libx264. The
  **GPU filter-consume rule** still applies on top: `resize to 1080p on
  the gpu` picks the CUDA filter (`scale_cuda`) and the mention is
  absorbed by the filter — an explicit encoder word (`nvenc`)
  re-enables GPU encoding
- **Muxer / format options** — `+faststart`, HLS segment settings
  (`hls_time`, segment type), MPEG-TS flags, MP3 ID3 tags, …, validated
  against the plan's actual output container
- **Watermarks** — one or several static images (preset positions, margin,
  percent scale): the first binds with `--watermark`, each extra one with
  `--asset name=image:file`; they overlay in the order the plan lists them;
  **audio replacement** from a second bound input, **audio keep / remove** —
  and compositions of any of the above, in the order stated
- **HDR → SDR tone-mapping** — `tone map this HDR clip to SDR`: detected
  from probe metadata (PQ / HLG transfer), built as
  `format=gbrpf32le,tonemap=tonemap=hable:desat=0,format=yuv420p` — the
  default output is 8-bit Rec.709, and a 10-bit `main10` re-encode keeps
  the HDR. HDR10+ and Dolby Vision are rejected explicitly
- **Batch mode** — `fass "resize to 720p" --batch clips/` (or an explicit
  file list) runs the same instruction over every top-level video file in a
  directory, one at a time; a failing file is reported and skipped, and
  `--batch-out DIR` sends every result into one folder
- **Subtitles** — bind an srt / ass / ssa / vtt file; **burned** into the
  video by default (libass, forces a re-encode) or muxed as a **selectable
  soft track** (MP4 / MOV / MKV — compatible with stream-copy)
- **Capture sources** — `lavfi:` synthetic sources, `v4l2:` cameras, and
  alsa / dshow / avfoundation / x11grab bind as typed inputs
- **Stream I/O** — inputs and outputs may be stream URLs (rtmp, rtsp, srt,
  http(s), udp, rtp, tcp — allowlisted); a stream destination's scheme fixes the
  container (rtmp→flv, rtsp→rtsp, srt→srt, udp/tcp→mpegts) and is disclosed
  in the response
- **Chained processings** — name the output `/input/<file>` (e.g.
  `/input/step1.mp4`) and the result is written into the input folder
  instead of the output folder, so the next command picks it up by bare
  name: `scale to 480p` → `/input/step1.mp4`, then `scale to 240p` on
  `step1.mp4`
- **Revisions** — pass the previous plan back (`--previous plan.json` on the
  CLI, `previous_plan` in the API) and only what the new instruction changes
  changes

The full web API (every endpoint — `POST /v1/commands`, `POST /v1/runs`,
the files / media / config endpoints), the security model, the validation
levels, the authentication posture and the curl examples live in
[API.md](API.md).

## Quality comparison (VMAF / PSNR / SSIM)

Measure how far a clip drifted from its reference — the Netflix vmaf docs'
command order, as a standalone analysis:

```bash
./.venv/bin/python -m fass "compare main.mp4 against ref.mp4 with psnr" main.mp4 --asset ref=video:ref.mp4
./.venv/bin/python -m fass "give me the vmaf against ref.mp4" main.mp4 --asset ref=video:ref.mp4
./.venv/bin/python -m fass "measure ssim between the two clips" main.mp4 --asset ref=video:ref.mp4
```

- **Reference binding** — the reference clip is bound with `--asset`
  (`--asset ref=video:ref.mp4`) and named in the request; a metric-less
  "compare against ref.mp4" / "how much quality loss" asks which metric
  (PSNR or SSIM — libvmaf is offered only when you name it)
- **Input order** — the reference is input 0 (the first `-i`), the main
  (distorted) input 1; the metric's pads take `[distorted][reference]`.
  When the sizes differ the main input is scaled to the reference's
  (the reference is the ground truth); fps / pixel-format mismatches are
  noted, not converted (resampling would distort the measurement)
- **Metrics** — `psnr` and `ssim` on every build; `libvmaf` needs a build
  that ships the filter (FFmpeg 7.0+ — present in the docker image's 9.0,
  absent from 6.1.1; the plan discloses it as a warning). The VMAF model
  comes from `FASS_VMAF_MODEL` (a full path) or `FASS_VMAF_MODEL_DIR`
  (`vmaf_v0.6.1.pkl` / `vmaf_v0.6.1.json`); with neither set, the
  filter's built-in model applies
- **Diagnostic output** — the scores go to the ffmpeg log (the run log /
  UI log tab, log level raised to info); the plan runs against the null
  muxer (`-f null -`) — **no output file is produced**
- **Standalone only** — a comparison cannot share one request with trims,
  watermarks, subtitles, audio replacement, combiners or filter edits;
  the NLU asks for a follow-up (apply the edit first, then compare the
  result against the reference)
- **Pointwise VMAF** — for frame-by-frame VMAF with a kept score file,
  use `POST /v1/vmaf` (the FFmpeg tab's "vmaf 1.0" button; see
  [HTTP API](#http-api)) instead: it deinterlaces/resizes to align the
  pair, scores over the shortest file and stores the JSON score in the
  scores volume with the exact command + steps that produced it
- **Timeline alignment** — `setpts=PTS-STARTPTS` re-bases each input's
  pad only when its probe shows the stream carries packet pts; a raw
  bitstream (a bare Annex-B `.hevc`) demuxes without any, so the filter
  is skipped for that pad and the run notes it (frames compare in
  arrival order)

## play2 — live side-by-side (SBS) HLS

The FFmpeg tab's **play2** button (next to **vmaf 1.0**) is a live
visual comparison: the current **Input** file on the **left** (the
source) and the current **Output** file on the **right** (the derived /
transcoded clip), encoded in real time and played in the **Player**
tab. Use it to eyeball a transcode against the original — desyncs,
banding, deinterlace artifacts — while it is still happening.

- **What you see** — two equal tiles (the bigger input's aspect),
  each inside a 1 px frame (**input** = green, **output** = blue), a
  20 px gap between the frames, an `input` / `output` label under each
  tile, and the play position in seconds in the bottom bar (`12.34
  s`) — all on a black 1920x1080 @ 60 canvas. Each clip is normalized
  first: deinterlace (interlaced frames only), constant 60 fps, scaled
  to the tile size, yuv420p — a drift between the two halves is
  visible immediately.
- **Encoding** — H.264 1920x1080 at 60 fps, GOP 20, CBR at the
  **bitrate play2 (kbps)** Config-tab field (default 5 000 = the 5M
  reference; the buffer is auto 2×) + AAC-LC 128 k/48 kHz, 2 s
  MPEG-TS segments in an **event** playlist (every segment is kept, so
  the Player can rewind through the whole comparison). A GPU
  deployment (`gpu.enabled` and `h264_nvenc` in the build) takes the
  GPU path — NVDEC decode, `yadif_cuda` / `scale_cuda` / `overlay_cuda`,
  `h264_nvenc`; a CPU box (or a stale `gpu.enabled` without the
  encoder) takes the CPU path — `bwdif` + `libx264` — and the run
  notes it. Audio is the source clip's (the left one).
- **The scripts own the presentation** — the pipeline and the encoding
  are two bash scripts baked into the image
  (`/opt/play2/sbs_hls_cpu.sh`, `/opt/play2/sbs_hls_nvidia.sh`); fass
  only launches them with absolute paths and env (`LOOP=1`, plus
  `VBIT` / `VBUF` from the bitrate field). Tweak titles, overlays or
  the encode by editing the scripts in `tests/double_view/` and
  rebuilding the image — fass never rewrites the pipeline.
- **It runs until stopped** — fass passes `LOOP=1` (`-stream_loop -1`
  on both inputs), so the comparison loops forever instead of dying
  after one pass; it is a live stream, not a file to finish.
- **The button tracks the real run** — play2 ↔ **Stop** (danger): a
  1.5 s poll of the run record flips the label back on its own
  whenever the run goes terminal, no matter where the stop came from —
  the button, the Player tab's stop, the Runs tab, a crash, or the run
  record vanishing. Re-entering the FFmpeg tab re-syncs it.
- **Where it lands** — a fixed stream tree `{output}/http/play2/`
  (wiped and recreated on every start), playlist
  `http/play2/stream.m3u8`, listed by `GET /v1/streams` and **live**
  in the Player tab's streams table while the run runs. On start the
  UI jumps to the Player tab and auto-plays once the first playlist
  lands.
- **Stop** — the ordinary run stop: the bash script and its child
  ffmpeg share one process group, so stopping the run kills both.
- **Gates** — bare filenames in BOTH fields (the vmaf 1.0 gate); 404 a
  file missing from its volume, 422 a non-video name, 409 a second
  play2 while one already plays, 503 with execution disabled or the
  script missing from the image.

The API is `POST /v1/streams/play2` (bare names, like `/v1/vmaf`):

```bash
curl -s http://127.0.0.1:8000/v1/streams/play2 \
  -H 'content-type: application/json' -d '{
    "input": "10_input1.ts",
    "output": "trans_720p.ts"
  }'
# → {"run_id": "…", "playlist": "http/play2/stream.m3u8",
#    "url": "http://127.0.0.1:3011/http/play2/stream.m3u8",
#    "encoder": "h264_nvenc"}
```

Stop it with the ordinary `POST /v1/runs/{run_id}/stop`.

## Docker deployment

The published image `boris271142/fass` (Docker Hub): fass compiled with
Cython, FFmpeg 9.0 + NVIDIA hardware acceleration, plus the
`boris271142/fass-rag` retrieval image. Four containers — `fass`, the
`fass-worker` Apply sidecar, the `fass-rag` lexical RAG retriever
(corpus index baked into its image, no volume), and the `fass-http`
Apache sidecar for HLS/DASH stream runs — up with one script:

```bash
./setup.sh                  # interactive: folders, LLM endpoint, ports, GPU
                            # → http://<host>:8000
./setup.sh --upgrade        # an older fass install runs here: remove its
                            # containers (the upgrade) without asking
./scripts/web.sh            # start / pull / restart / stop / status / logs
```

The image's FFmpeg (base `boris271142/ffmpeg-sm_75_120`, a rebuild of
`jrottenberg/ffmpeg` 9.0.2) is compiled with **CUDA compute
compatibility 7.5** — the compute capability of NVIDIA's **Turing**
generation: its CUDA filter stack (`scale_cuda`, `overlay_cuda`, the
`hwupload`/`hwdownload` bridges, GPU decode) is built as **compute_75
PTX**, which the driver JITs forward to every newer architecture up to
**sm_120**. Supported NVIDIA card generations:

- **Turing (sm_75)** — GeForce RTX 20 series (2070 / 2080 / 2080 Ti), T4
- **Ampere (sm_80 / sm_86)** — A100, A10 / A30 / A40, GeForce RTX 30
  series (3060 – 3090 Ti), RTX A2000 – A6000
- **Ada Lovelace (sm_89)** — L4 / L40 / L40S, GeForce RTX 40 series,
  RTX 4000 Ada
- **Hopper (sm_90)** — H100 / H200
- **Blackwell (sm_100 / sm_120)** — B100 / B200 / GB200, GeForce RTX 50
  series

So **Turing (2018) and every newer generation works**; older generations
— Pascal (sm_61: GTX 10xx, P4 / P100), Volta (sm_70: V100) and anything
earlier — are **not** supported. (The stock `jrottenberg/ffmpeg` image
goes the other way: its CUDA kernels cover sm_86 only, breaking cards
older than Ampere — which is why the base is rebuilt.) The floor applies
to the CUDA *filters*: NVENC / NVDEC / CUVID are header-only (ffnvcodec)
driver APIs and are not gated by it.

The base also builds **libvmaf with CUDA** — the `libvmaf_cuda` filter
that the VMAF tab's `on gpu` path scores with. That rebuild matters:
libvmaf 3.0.0's meson embeds each CUDA kernel as bare `nvcc --ptx` with
no arch flag, so it defaults to **sm_52** PTX that modern drivers no
longer JIT — the filter looks present, then `assert(0)`s in
`init_fex_cuda` on first use. The base recompiles the kernels as a
sm_75-PTX + sm_86-SASS fatbin (JIT-able across the same sm_75…sm_120
range) and hard-fails the build if any kernel module is not a fatbin;
it also bundles the CUDA compat driver at the path the nvidia container
runtime mounts the host driver to, so GPU-less containers (the
`fass-worker` sidecar) can launch the ffmpeg binary at all. Full detail:
the base builder's README
([suedenglehem/jrottenberg-ffmpeg-sm_75_120](https://github.com/suedenglehem/jrottenberg-ffmpeg-sm_75_120)).

The web UI gets a **Config tab**: host-folder mappings for `/input`,
`/output`, `/log` (each optionally mapped to a remote FTP / SFTP / SCP
/ S3 store), stream port mappings (in: `udp://host:port` binds to `0.0.0.0`
inside; out: `srt/rtmp://host:port` rewrites to the docker gateway),
GPU on/off (on → H.265 and, when the GPU can, AV1 are nvenc-encoded by
default; H.264 stays on libx264), and the LLM provider (Anthropic, or
any OpenAI-compatible endpoint). Execution is enabled in the
image: the UI's **Runs** tab starts the generated command inside the
container, follows its log live, stops it, and links the result file; an
output named `/input/<file>` lands in the input volume so a later run can
pick it up by bare name (chained processings). The Config tab's
**Apply** button recreates the container from the saved config via a
`fass-worker` sidecar (a container cannot recreate itself). Full details:
[docker/README.md](docker/README.md).

**Multicast input/output** — multicast does not cross the compose
bridge's NATted ports, so for it fass runs in the **host network
namespace**: add `network_mode: host` to the `fass` service in
`docker/compose.yaml` (plus the two sidecar port/URL tweaks it needs —
the details at the end of this paragraph). Only `fass` goes host-mode
(the sidecars stay on the bridge, reachable on `127.0.0.1`), so a
multicast group source works
verbatim — a minute of `239.1.1.1:1234` on host NIC `192.168.0.30`, in
the Runs tab's Enter mode:

```sh
ffmpeg -i "udp://239.1.1.1:1234?localaddr=192.168.0.30&fifo_size=1000000&overrun_nonfatal=1" \
  -t 60 -c copy /output/multicast.ts
```

The host firewall must allow the group's UDP port (`sudo ufw allow
1234/udp`) — without it the receiver fails silently. The Config tab's
Streaming section shows a green/red **multicast** indicator right of
the section title — **what it is for**: whether the *kernel side* is
multicast-capable, the prerequisite for receiving a multicast group
source at all. At process start (once per process, cached — also in
`GET /v1/env` and the container log) fass runs `ip link show` over
every container interface: green **multicast enabled** when at least
one interface carries the MULTICAST flag, red **multicast disabled**
when none, a neutral note when it cannot be determined. Linux sets the
flag by default, so it stays green in bridge mode too — what actually
makes the host's groups reachable is host network mode + the host
firewall, as above. Full setup, the sender example and the compose
tweaks:
[docker/README.md — Multicast](docker/README.md#multicast-host-network-mode).

**RIST input/output** — the base image's ffmpeg speaks `rist://`
natively (ffmpeg 9.0.2 + librist 0.2.20, built into
`boris271142/ffmpeg-sm_75_120`). A working send/receive pair, verified
end-to-end (8 s of
1280x720 H.264, 4.7 MB received, loopback):

```sh
# 1 · receiver FIRST — the @ switches the URL to a listening socket
ffmpeg -i "rist://@0.0.0.0:5000?rist_profile=main" \
  -map 0 -c copy received.ts

# 2 · sender (second shell — docker exec -it fass bash)
ffmpeg -re -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p -g 30 \
  -f mpegts \
  "rist://127.0.0.1:5000?rist_profile=main"
```

- **Start the receiver first** — the `@` before the host marks a
  *listening* socket (no `@` = connect to a remote). A sender that
  starts first finds nothing to handshake with; receiver, then sender.
- **`?rist_profile=main` is a no-op** — main is librist's built-in
  default profile, and `rist_profile` is NOT a librist URL parameter:
  the session runs identically without it, with a benign
  `Unknown or invalid parameter rist_profile` line on stderr (librist
  parses the URL query itself and warns about what it doesn't know).
- **The reader never self-terminates** — when the sender stops, the
  main-profile session times out ("Session Timeout after 2s of no
  data") but the read loop keeps polling with a frozen frame count;
  stop the reader explicitly (Ctrl-C / kill).
- **The sender's final error is cosmetic** — at teardown it exits
  non-zero with `Error closing file: Generic error in an external
  library`; every frame was already delivered.
- **Read without saving** —
  `ffmpeg -i "rist://@0.0.0.0:5000?rist_profile=main" -f null -`; the
  running `frame=` / `time=` stats are the proof the stream flows.
- **Verbose librist logs** — librist's INFO level maps to ffmpeg's
  VERBOSE, so `-loglevel verbose` is what shows the session lines; the
  `Failed to set data output thread to RR scheduler with prio of 99`
  warning is benign (no `CAP_SYS_NICE` in the container).
- **In fass itself** — `rist://` is on the stream-URL allowlist: a
  `rist://` URL works in the FFmpeg tab's Input / Output fields and in
  Enter mode (a stream destination fixes the container to mpegts,
  like every other live scheme). Cross-host, the port is plain UDP —
  expose it in the compose file.
## Safety

- argv arrays only — model output is schema-validated, the builder emits
  flags from a fixed vocabulary; no shell, no eval
- **no execution by default** — the service only generates, and a human
  reviews and runs the command. Execution is an opt-in per deployment
  (`FASS_ALLOW_EXECUTE=1`; the docker image sets it). Even there, only argv
  from the builder's own fixed vocabulary can run — every flag, codec,
  format, filter and value is checked against the registry before the
  process starts, and paths resolve into the deployment's input / output
  volumes (see [docker/README.md](docker/README.md#execution))
- run output is served back only when the file lives inside the input or
  output volume — never a path outside them
- asset URLs are limited to an allowlist of streaming schemes (`file://`,
  `ftp://`, … are rejected)
- output never overwrites the input; `-y` is emitted only when the
  Config tab's "output file already exists → overwrite it" option is
  on (default off — a standard warning is issued instead)

Published at github.com/suedenglehem/fass-cython (branch main).
