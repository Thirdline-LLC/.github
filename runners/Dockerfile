# Single-use runner image for Thirdline-LLC (docs/progress.md, step A3).
#
# Built on ASHERPC in each WSL distro and never pushed anywhere:
#   docker build -t thirdline-runner:2.338.2 runners/
# Each CI job runs in a fresh container from this image, which is deleted afterwards.
#
# Everything is pinned: the base image by digest, Node by version and checksum, Playwright by
# version. To update, change the pins here and rebuild (runners/README.md, "Rebuilding").

FROM ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300

USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Base tools and PostgreSQL 16 (for pg-start.sh). gh comes from its GitHub release, checked
# against the published checksum: its apt repo keeps only the newest version, so it can't be
# pinned there. 2.103.3 was the newest release at least two weeks old on 2026-11-18.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl jq xz-utils git python3 \
      postgresql-16 postgresql-client-16 \
 && curl -fsSL https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_linux_amd64.deb -o /tmp/gh.deb \
 && echo "e3bafef96328d1a67de3a968bdfe1cc2ffd58cf6aba8b5e201356897ed06bb3d  /tmp/gh.deb" | sha256sum -c - \
 && apt-get install -y -qq /tmp/gh.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/gh.deb \
 # The package makes a cluster and a service; jobs start their own with pg-start.sh.
 && (pg_dropcluster 16 main 2>/dev/null || true)

# Node in the tool cache layout actions/setup-node looks for, so jobs don't download it.
# Versions are the newest of each line that was at least two weeks old on 2026-11-18.
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
RUN for pair in \
      20.20.2:df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d \
      22.23.4:1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce \
      24.22.2:48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75; do \
      v=${pair%%:*}; sum=${pair#*:}; f=node-v$v-linux-x64.tar.xz; \
      curl -fsSL "https://nodejs.org/dist/v$v/$f" -o "/tmp/$f"; \
      echo "$sum  /tmp/$f" | sha256sum -c -; \
      mkdir -p "$RUNNER_TOOL_CACHE/node/$v/x64"; \
      tar -xJf "/tmp/$f" -C "$RUNNER_TOOL_CACHE/node/$v/x64" --strip-components=1; \
      touch "$RUNNER_TOOL_CACHE/node/$v/x64.complete"; \
      rm "/tmp/$f"; \
    done \
 && ln -s "$RUNNER_TOOL_CACHE/node/22.23.4/x64/bin/node" /usr/local/bin/node \
 && ln -s "$RUNNER_TOOL_CACHE/node/22.23.4/x64/bin/npm" /usr/local/bin/npm \
 && ln -s "$RUNNER_TOOL_CACHE/node/22.23.4/x64/bin/npx" /usr/local/bin/npx \
 && chown -R runner:runner "$RUNNER_TOOL_CACHE"

# Chromium's system libraries, so Playwright jobs need no sudo. Browsers themselves come from
# each job's own actions/cache (they're tied to the repo's Playwright version).
RUN npx -y playwright@1.64.1 install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

COPY pg-start.sh /usr/local/bin/pg-start.sh
RUN chmod 755 /usr/local/bin/pg-start.sh
ENV PATH=/usr/lib/postgresql/16/bin:$PATH

USER runner
WORKDIR /home/runner
