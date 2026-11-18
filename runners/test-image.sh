#!/usr/bin/env bash
# A3's finish line: run the image with the same limits a runner slot gets, and check that
# Node, gh, PostgreSQL and Chromium all work inside it. Run as root on the runner host:
#   runners/test-image.sh thirdline-runner:2.338.2
set -euo pipefail
image=${1:?usage: test-image.sh <image>}

docker run --rm \
  --memory 3g --pids-limit 4096 --shm-size 1g \
  --security-opt no-new-privileges \
  "$image" bash -euo pipefail -c '
    echo "node $(node -v)"
    ls /opt/hostedtoolcache/node
    gh --version | head -n 1
    out=$(pg-start.sh); echo "$out" | head -n 1; eval "$(echo "$out" | tail -n 1)"
    echo "psql: $(psql -tAc "select 1")"
    mkdir -p /tmp/pw && cd /tmp/pw
    npm init -y > /dev/null
    npm install --silent --no-audit --no-fund playwright@1.64.1 > /dev/null
    npx playwright install chromium > /dev/null
    node -e "
      const { chromium } = require(\"playwright\");
      (async () => {
        // The container is the sandbox: Chromium can'\''t make its own without extra privileges.
        const b = await chromium.launch({ chromiumSandbox: false });
        const p = await b.newPage();
        await p.goto(\"about:blank\");
        console.log(\"chromium:\", b.version(), \"opened\", p.url());
        await b.close();
      })().catch(e => { console.error(e); process.exit(1); });
    "
  '
echo "A3 image check: PASS"
