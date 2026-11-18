#!/usr/bin/env bash
# scripts/create-db.sh — offline creation of the fass database.
#
# For fresh hosts (setup.sh runs this before the stack comes up), for
# pre-provisioned databases, or for recovery on a machine where the
# stack is down: pulls the pgvector/pgvector:pg16 image when the
# fass-db container is not running and must be started, creates the
# role + database, and applies the FULL fass schema (v2) with the
# major-version stamp — without the fass app involved.
#
# Safety — mirrors the fass/db.py connect() gate:
#   * every statement is CREATE ... IF NOT EXISTS / INSERT ... ON
#     CONFLICT DO NOTHING in a single transaction: never destructive,
#     re-running on a complete database is a no-op;
#   * a database whose stored major version differs from the one the
#     script stamps is REFUSED (exit 1, "do manual migration") and
#     never touched;
#   * the stamp is written only when absent (ON CONFLICT DO NOTHING) —
#     a stamped-matching or un-stamped database passes, and an
#     un-stamped one is stamped (fass stamps it the same way on first
#     connect).
#
# Usage:
#   scripts/create-db.sh                  # full: container (if needed) + role + db + tables + stamp
#   scripts/create-db.sh --bare           # role + database only, no tables
#   scripts/create-db.sh --status         # read-only state report
#   scripts/create-db.sh --major 1.618033 # explicit major-version stamp
#
# Environment overrides:
#   FASS_DB_CONTAINER  fass container name (default fass-db)
#   FASS_DB_NAME       database name       (default ffmpeg_assisstant)
#   FASS_DB_USER       role                (default ffmpeg)
#   FASS_DB_PASSWORD   role password       (default ffmpeg)
#   FASS_DB_DIR        data dir when THIS script starts the container
#                      (default <repo>/docker-data/db — the same
#                      volume docker/compose.yaml mounts, so a
#                      script-started container is exactly the one
#                      `docker compose up` would run)
#   FASS_MAJOR_VERSION stamp value (source 2 of 3: --major wins, then
#                      this, then this repo's fass/version.py)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTAINER="${FASS_DB_CONTAINER:-fass-db}"
DB_NAME="${FASS_DB_NAME:-ffmpeg_assisstant}"
DB_USER="${FASS_DB_USER:-ffmpeg}"
DB_PASS="${FASS_DB_PASSWORD:-ffmpeg}"
DB_DIR="${FASS_DB_DIR:-$REPO_ROOT/docker-data/db}"
PG_IMAGE="pgvector/pgvector:pg16"
SCHEMA_VERSION=2

BARE=0
STATUS=0
MAJOR="${FASS_MAJOR_VERSION:-}"

die() { echo "create-db: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
scripts/create-db.sh — offline creation of the fass database

  (no flags)              container (if needed) + role + db + full schema + stamp
  --bare                  role + database only, no tables
  --status                read-only state report
  --major MAJOR           explicit major-version stamp (e.g. 1.618033)

Environment: FASS_DB_CONTAINER, FASS_DB_NAME, FASS_DB_USER,
             FASS_DB_PASSWORD, FASS_DB_DIR, FASS_MAJOR_VERSION
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bare) BARE=1; shift ;;
    --status) STATUS=1; shift ;;
    --major) MAJOR="${2:?--major needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "create-db: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# psql <db> <sql args...> — as $DB_USER when that role exists, else as
# postgres (always present in the pg image; local trust auth, so no
# password is ever needed from inside the container).
ADMIN_USER=""
psql() {
  local db="$1"; shift
  if [[ -z "$ADMIN_USER" ]]; then
    # NO -i here: a -i exec drains this shell's stdin (a heredoc fed to
    # a later call in the same function would be lost to the probe).
    if docker exec "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" \
        -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
      ADMIN_USER="$DB_USER"
    else
      ADMIN_USER="postgres"
    fi
  fi
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$db" "$@"
}

# container state or "missing" (the docker CLI prints a stray blank
# line to stdout on inspect errors, so strip whitespace before matching)
container_state() {
  local s
  s="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
  s="${s//[$' \t\r\n']/}"
  [[ -n "$s" ]] || s="missing"
  printf '%s' "$s"
}

ensure_container() {
  local state
  state="$(container_state)"
  case "$state" in
    running)
      ;;
    missing)
      if ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
        echo "image $PG_IMAGE not local — pulling"
        docker pull "$PG_IMAGE" || die "pull of $PG_IMAGE failed"
      fi
      mkdir -p "$DB_DIR"
      echo "starting $CONTAINER from $PG_IMAGE (data dir: $DB_DIR)"
      docker run -d --name "$CONTAINER" --restart unless-stopped \
        --health-cmd "pg_isready -U $DB_USER" \
        --health-interval 10s --health-timeout 5s --health-retries 5 \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASS" \
        -e POSTGRES_DB="$DB_NAME" \
        -v "$DB_DIR:/var/lib/postgresql/data" \
        "$PG_IMAGE" >/dev/null || die "docker run failed for $CONTAINER"
      ;;
    *)
      echo "container $CONTAINER is '$state' — starting it"
      docker start "$CONTAINER" >/dev/null || die "docker start failed for $CONTAINER"
      ;;
  esac
  local i
  for i in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -q -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "$CONTAINER is not accepting connections after 60 s — docker logs $CONTAINER"
}

# How many of fass's own 6 tables exist (the same set the connect gate
# checks in fass/db.py).
table_count() {
  psql "$1" -tAc "SELECT count(*) FROM information_schema.tables
                  WHERE table_schema = 'public'
                    AND table_name IN ('schema_version','settings','runs','run_logs','workers','meta')"
}

# The exact fass v2 schema, verbatim from fass/db.py (schema_version
# bookkeeping + migrations 1 and 2), all idempotent, one transaction.
apply_schema() {
  local stamp_sql=""
  if [[ -n "$MAJOR" ]]; then
    stamp_sql="INSERT INTO meta (key, value) VALUES ('major_version', '$MAJOR')
  ON CONFLICT (key) DO NOTHING;"
  fi
  # -q: no command-tag spam on an idempotent re-run; the SET below
  # silences the server NOTICE (relation already exists) — psql's -q
  # alone does not cover server notifications. The run is a no-op
  # either way; ON_ERROR_STOP still fails loudly on a real error.
  psql "$DB_NAME" -q --single-transaction <<SQL
SET client_min_messages TO WARNING;
CREATE TABLE IF NOT EXISTS schema_version (
      version    INTEGER PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
CREATE TABLE IF NOT EXISTS settings (
      key         TEXT PRIMARY KEY,
      value       JSONB NOT NULL,
      updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );
CREATE TABLE IF NOT EXISTS runs (
      run_id       TEXT PRIMARY KEY,
      rec          JSONB NOT NULL,
      started      TIMESTAMPTZ,
      finished     TIMESTAMPTZ,
      status       TEXT,
      command      TEXT,
      duration_s   DOUBLE PRECISION,
      worker_id    TEXT,
      fass_version TEXT
  );
CREATE INDEX IF NOT EXISTS runs_started_idx ON runs (started DESC);
CREATE INDEX IF NOT EXISTS runs_worker_idx ON runs (worker_id);
CREATE TABLE IF NOT EXISTS run_logs (
      run_id   TEXT PRIMARY KEY
             REFERENCES runs (run_id) ON DELETE CASCADE,
      log      TEXT
  );
CREATE TABLE IF NOT EXISTS workers (
      worker_id  TEXT PRIMARY KEY,
      host       TEXT,
      role       TEXT NOT NULL DEFAULT 'master+worker',
      started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      last_seen  TIMESTAMPTZ NOT NULL DEFAULT now()
  );
CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT
  );
INSERT INTO schema_version (version) VALUES (1) ON CONFLICT DO NOTHING;
INSERT INTO schema_version (version) VALUES (2) ON CONFLICT DO NOTHING;
$stamp_sql
SQL
}

report_status() {
  local state
  state="$(container_state)"
  echo "container:   $CONTAINER ($state)"
  if [[ "$state" != "running" ]]; then
    echo "not running — nothing to report"
    return 0
  fi
  echo "data dir:    $DB_DIR"
  local have_role have_db n
  have_role="$(psql postgres -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$DB_USER'")"
  have_db="$(psql postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$DB_NAME'")"
  if [[ "$have_role" == 1 ]]; then echo "role:        $DB_USER (present)"; else echo "role:        $DB_USER (MISSING)"; fi
  if [[ "$have_db" == 1 ]]; then echo "database:    $DB_NAME (present)"; else echo "database:    $DB_NAME (MISSING)"; fi
  [[ "$have_db" == 1 ]] || return 0
  n="$(table_count "$DB_NAME")"
  echo "fass tables: $n/6"
  [[ "$n" -gt 0 ]] || return 0
  echo "schema:      v$(psql "$DB_NAME" -tAc "SELECT COALESCE(MAX(version),0) FROM schema_version")"
  echo "major stamp: $(psql "$DB_NAME" -tAc "SELECT COALESCE((SELECT value FROM meta WHERE key='major_version'),'(un-stamped)')")"
  local rows
  # count(*) is never NULL, so no COALESCE — and no COALESCE either:
  # PostgreSQL would infer the type from the bigint arm and reject the
  # text fallback.
  rows="$(psql "$DB_NAME" -tAc "SELECT
      'runs='||(SELECT count(*) FROM runs)
    || ' settings='||(SELECT count(*) FROM settings)
    || ' workers='||(SELECT count(*) FROM workers)
    || ' run_logs='||(SELECT count(*) FROM run_logs)" 2>/dev/null || true)"
  echo "rows:        ${rows:-unavailable}"
}

main() {
  if [[ $STATUS -eq 1 ]]; then
    report_status
    exit 0
  fi

  # Stamp value, in source order: --major (1), FASS_MAJOR_VERSION (2,
  # pre-loaded into MAJOR), this repo's fass/version.py (3 — dev trees
  # only; the public repo ships the compiled wheel, so the file is
  # absent there and the db stays un-stamped — fass stamps it on first
  # connect).
  if [[ -z "$MAJOR" && -f "$REPO_ROOT/fass/version.py" ]]; then
    local raw
    raw="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$REPO_ROOT/fass/version.py" | head -1)"
    raw="${raw#v}"
    MAJOR="${raw%.*}"
  fi
  if [[ -n "$MAJOR" ]] && ! [[ "$MAJOR" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    die "major version must be dotted numbers (got: $MAJOR)"
  fi

  [[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "FASS_DB_NAME must be a plain identifier: $DB_NAME"
  [[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "FASS_DB_USER must be a plain identifier: $DB_USER"
  local db_pass_sql="${DB_PASS//\'/\'\'}"

  ensure_container

  # Role + database: no-ops when the image entrypoint already made
  # them on first init (POSTGRES_USER is created as a superuser,
  # POSTGRES_DB owned by it) — kept for containers started any other
  # way.
  local have_role
  have_role="$(psql postgres -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$DB_USER'")"
  if [[ "$have_role" != 1 ]]; then
    echo "creating role $DB_USER"
    psql postgres -c "CREATE ROLE \"$DB_USER\" LOGIN SUPERUSER PASSWORD '$db_pass_sql'"
  fi
  local have_db
  have_db="$(psql postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$DB_NAME'")"
  if [[ "$have_db" != 1 ]]; then
    echo "creating database $DB_NAME"
    psql postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\""
  fi

  local n
  n="$(table_count "$DB_NAME")"

  if [[ $BARE -eq 1 ]]; then
    if [[ "$n" -gt 0 ]]; then
      echo "bare: role + database present; $n/6 fass tables already there — left untouched"
    else
      echo "bare: role + database ready — no tables; fass does the full one-shot init (schema + seed) on first connect"
    fi
    exit 0
  fi

  local stored=""
  if [[ "$n" -gt 0 ]]; then
    # Tables present — mirror the connect gate: a different stored
    # major is refused and never touched.
    stored="$(psql "$DB_NAME" -tAc "SELECT COALESCE((SELECT value FROM meta WHERE key='major_version'),'')")"
    if [[ -n "$stored" && -n "$MAJOR" && "$stored" != "$MAJOR" ]]; then
      die "REFUSED — the database is stamped major '$stored', this build stamps '$MAJOR' — do manual migration (nothing was touched)"
    fi
    echo "ok: $n/6 fass tables already present — idempotent top-up (a no-op on a complete schema)"
    apply_schema
    if [[ -n "$MAJOR" && -z "$stored" ]]; then
      echo "stamped major version $MAJOR (was un-stamped)"
    fi
  else
    echo "no fass tables — creating the full schema (v$SCHEMA_VERSION)"
    apply_schema
    if [[ -n "$MAJOR" ]]; then
      echo "stamped major version $MAJOR"
    else
      echo "note: no major-version source (use --major or FASS_MAJOR_VERSION) — the database stays un-stamped; fass stamps it on first connect"
    fi
  fi

  echo "database ready:"
  report_status
}

main
