#!/usr/bin/env bash
# Start a throwaway PostgreSQL 16 for one CI job, then hand its address to later steps.
#
# Installed by the runner host or image (never from a PR), at /usr/local/bin/pg-start.sh.
# Replaces a `services: postgres` container, which needs Docker inside the job.
#
# Usage in a workflow step:   pg-start.sh
# Afterwards, later steps get PGHOST, PGPORT and PGUSER (user `postgres`, no password,
# listening on 127.0.0.1 only). Create databases and users with psql in the next step.
# The data lives in the job's temp folder, so it disappears with the job.
set -euo pipefail

PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
[ -x "$PGBIN/initdb" ] || { echo "::error::PostgreSQL 16 isn't installed on this runner ($PGBIN)"; exit 1; }

dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pg.XXXXXX")
# Ask the kernel for a free port, so two jobs on one host never collide.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

"$PGBIN/initdb" -D "$dir/data" -U postgres --auth=trust -E UTF8 --no-instructions >/dev/null
"$PGBIN/pg_ctl" -D "$dir/data" -l "$dir/server.log" -w \
  -o "-p $port -k $dir -c listen_addresses=127.0.0.1 -c fsync=off" start >/dev/null

echo "PostgreSQL 16 is up on 127.0.0.1:$port (data in $dir)"
if [ -n "${GITHUB_ENV:-}" ]; then
  { echo "PGHOST=127.0.0.1"; echo "PGPORT=$port"; echo "PGUSER=postgres"; } >> "$GITHUB_ENV"
else
  echo "export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres"
fi
