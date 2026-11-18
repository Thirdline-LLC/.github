# Progress: single-use runners and a queue that stays out of main's cache

Plan written 2026-11-18, revised the same day after the plan check (`omega-plan-griller`, 13
holes). Not started: waits for Asher's "go".

Both plans come from the 2026-11-16 security assessment fixes. They close two risks that PR code
still has today:

1. **Runners keep their disk.** The Alienware runners (WSL distros `thirdline-pool` and `tapin-ci`)
   reuse one Linux user and home folder for every job. A job can leave files behind (a poisoned
   npm cache, a line in `~/.bashrc`) that the next job, possibly a run on `main`, picks up.
2. **Queued PR code runs in main's cache scope.** The queue is a `workflow_dispatch` run on `main`
   that calls each repo's CI with the PR's code, so that code can write caches that later `main`
   runs restore. CodeQL on NFC reports this as 4 high `actions/cache-poisoning` alerts.

Decisions already made (Asher, 2026-11-18): a **GitHub App** holds the runner credential; each job
runs in a **fresh Docker container**, deleted afterwards; **all runners switch at once**; queued
tests run on a temporary branch using **the PR's own CI file**, the same trust its PR checks get.

Facts checked 2026-11-18:
- Org runner groups work on our plan: group `thirdline-pool` (id 3, all repos) already exists.
  NFC's runners are registered to the NFC repo, not the org.
- `gh workflow run` (gh 2.104) prints the created run's URL, so the queue gets the run id directly
  instead of searching for it.
- Neither distro has PostgreSQL installed. `tapin-ci` has no Docker. Pool runners have a CPU pin
  (28-31) and no memory cap.
- Both distros boot with systemd (`/etc/wsl.conf` `systemd=true`); the pool distro has Windows
  drives and interop turned off.

Out of scope: GitHub Code Security for the private repos (paid licence, Asher's call), Vercel's
"Deployment was blocked" on staffing (Asher: no), NFC's `build-mac.yml` (runs on `macos-14`).

How changes land: consumer repos through their queue. This repo (`.github`) has no queue and no
required checks, so its PRs are merged by Asher.

## Plan A: single-use runners

Design. Each runner slot is a systemd unit (`thirdline-runner@<slot>.service`, `Restart=always`)
running a loop: make an App JWT → swap it for a 1-hour installation token → ask GitHub for a
just-in-time (JIT) runner config for this slot → `docker run --rm` the runner image with it → the
runner takes exactly one job and exits → the container is deleted → loop. JIT configs are
single-use, so no long-lived registration token exists. The App's private key is the only stored
secret, and only the supervisor reads it.

Container limits for every slot: `--cpuset-cpus` (the slot's current CPUs), `--memory 3g`
(slot split and the measured peak are in A5c), `--pids-limit 4096`,
`--shm-size 1g` (Chromium crashes in Docker's 64 MB default), `--security-opt no-new-privileges`,
a size-capped writable layer, no `--privileged`, no host Docker socket. Chromium runs with its
own sandbox off inside the container (`--no-sandbox` through Playwright's `chromiumSandbox:
false`), because the container is the sandbox. Known limit, written in the README: containers can
still reach the Windows host and the LAN over the network.

- [ ] **A1. GitHub App** (Asher, in the browser, about 5 minutes). Org-owned app
      `thirdline-runners`, one permission (*Organization → Self-hosted runners: Read and write*),
      no webhook, installed on Thirdline-LLC only. The private key goes Mac → `scp` to ASHERPC →
      into each distro, with no cloud copy, then is deleted from Downloads.
      Done when: `gh api /orgs/Thirdline-LLC/installations --jq '.installations[].app_slug'` lists
      it, and `stat -c '%U %a' /etc/thirdline-runners/app.pem` prints `root 600` in both distros.
- [ ] **A2. Runner groups.** Groups and repo access:
      `thirdline-pool` (exists) → all repos (CodeQL and Code Quality use it);
      `tapin` (new) → NFC-Attendance-Scanner only;
      `queue` (new) → NFC, build-team, cclp, scholars.
      Labels stay as they are (`thirdline-pool`, `tapin`, `thirdline-queue`), so no workflow changes.
      Done when: `gh api /orgs/Thirdline-LLC/actions/runner-groups` lists all three, and each
      group's `/repositories` matches the list above. (The pickup test needs JIT runners, so it is
      in A5c.)
- [ ] **A3. Runner image** `runners/Dockerfile`, from `ghcr.io/actions/actions-runner` pinned by
      digest, adding Node 20 and 22, gh, jq, PostgreSQL 16 (with `/usr/lib/postgresql/16/bin` on
      PATH), Playwright's system libraries and `runners/pg-start.sh` (see A6). Built locally in each
      distro; never pushed anywhere. Runner self-update is off (`--disableupdate`), so the image
      must be rebuilt when GitHub ships a new runner (A9).
      Done when, inside a container from the image: `node -v`, `gh --version` (2.104 or later,
      which prints a dispatched run's URL; Plan B needs that), Playwright launches
      Chromium and opens `about:blank`, and `pg-start.sh` brings up Postgres and `psql -c 'select 1'`
      answers.
- [ ] **A4. Docker in `tapin-ci`** from Docker's apt repo, as in `thirdline-pool`.
      Done when: `docker run --rm hello-world` works there.
- [ ] **A5a. Token script** `runners/jit-config.sh <slot>`: JWT (with `iat` 60 s in the past, to
      allow for WSL clock drift), installation token, JIT config for the slot's group and labels.
      Has `--dry-run`. Errors back off (30 s, doubling to 10 min) instead of retrying in a loop.
      Done when: a dry run prints a JIT config; with the clock set 15 minutes wrong it fails with a
      clear message and backs off.
- [ ] **A5b. Supervisor and unit** `runners/supervise.sh` and `thirdline-runner@.service`, with the
      container limits above. At most one waiting runner per slot.
      Done when: test slot `asherpc-test-1` (label `thirdline-test`) runs two jobs in a row.
- [ ] **A5c. Failure, isolation and group tests** on the test slot, each written down in
      TESTING.md: the second job can't see a file the first wrote to `$HOME`; killing the container
      mid-job fails that job and the slot comes back; after `wsl --shutdown` the units start again
      by themselves; a slot with no job for 2 hours doesn't pile up registrations. Group pickup:
      the test slot is registered once in each group (`thirdline-pool`, `tapin`, `queue`) with a
      throwaway label, and a `workflow_dispatch` job from each repo that group allows is picked up.
      Memory: a worst-case job (cclp `playwright` while Postgres runs) under `--memory 3g`, peak
      recorded. Slots per distro: `thirdline-pool` 3 (pool-1j, pool-2j, poolq-1j = 9 GB of 15),
      `tapin-ci` 4 (tapin-1j..3j, queue-1j = 12 GB of 15). If the measured peak plus Docker doesn't
      fit in `tapin-ci`, run 2 tapin slots there instead of 3, and write that down.
- [ ] **A6a. Postgres on today's pool hosts.** Install PostgreSQL 16 and `pg-start.sh`
      (`/usr/local/bin`, root-owned) in the `thirdline-pool` distro, where cclp and scholars run
      today. This lets A6 merge before the switch and keeps cclp and scholars working if A8 is
      rolled back. Done when: `pg-start.sh` brings up Postgres as `poolrun1` and `psql -c 'select 1'`
      answers.
- [ ] **A6. Postgres inside the job** (cclp and scholars use a `services:` container, which needs
      Docker inside the job). `runners/pg-start.sh` ships in the image and on the old pool hosts
      (A6a), outside PR control. It
      initialises a cluster in the job's temp dir, starts it on a free port and exports
      `DATABASE_URL`. Each workflow creates what it needs: `cclp_supply_test` for cclp, user
      `cipguser` and database `cipgdb` for scholars. The same PR per repo also does A7's cache
      check, so each CI file changes once.
      Done when: `test` (cclp) and `be` (scholars) pass both on today's pool runners (the PR's own
      checks) and on the test slot (a branch that points `runs-on` at `thirdline-test`), before
      anything switches.
- [ ] **A7. Caches at GitHub.** Containers start empty, so npm packages and Playwright browsers come
      from `actions/cache`. Add it wherever a CI job lacks it (same PRs as A6).
      Done when: a second run of each PR shows cache hits in its logs.
- [ ] **A8. Switch all runners** in both distros, with **new names** (`pool-1j`, `pool-2j`,
      `poolq-1j`, `tapin-1j`..`3j`, `queue-1j`), same labels and groups. The old services are
      stopped and disabled, **not unregistered**: they show offline and stay ready for rollback.
      Done when, all on the new runners: one PR goes green in each of NFC, build-team, cclp,
      scholars and staffing's branch checks; the queue merges one PR end to end; one CodeQL run
      and one Code Quality run on NFC succeed.
- [ ] **A9. Write it down and prove the rollback.** `runners/README.md`: how it works, App key
      rotation and revocation, image rebuilds (monthly, and whenever GitHub warns that a runner is
      too old), known limits, rollback. Update NFC's `docs/ci-runner.md`; M-Brain dev log entry.
      Done when: the rollback was run once for real on one old runner (`asherpc-pool-2`
      re-enabled, a job runs on it, then it is stopped again), and a week after A8 the old
      registrations are removed.

Rollback after A8, under five minutes: `systemctl disable --now 'thirdline-runner@*'`, then
`systemctl enable --now` the old `actions.runner.*` services. They are still registered, so they
come straight back online.

Costs: jobs get 1 to 3 minutes slower when a cache misses; about 5 seconds otherwise.
If the App key leaks, someone can add runners to the org and take jobs. Revoke it by deleting the
key in the App's settings (README).

## Plan B: queue tests outside main's cache

Design. For every PR in state `test`, `prepare` now always pushes a branch
`merge-queue/test-<pr>-<run>` at `test_ref`, including the cases where it used GitHub's merge ref
or the PR head (that pattern is what its stale-branch sweep and `finish`'s delete already match).
A new job `wait` dispatches each CI workflow named by the caller on that branch
(`gh workflow run <file> --ref merge-queue/test-...`), takes the run id from the URL it prints,
and follows those runs to the end. Their cache scope is the test branch: they can read main's
caches, and anything they write stays on that branch. `finish` then deletes the branch **and its
caches** (`gh cache delete --all --ref refs/heads/merge-queue/test-...`; deleting a branch alone
doesn't delete its caches).

`wait` accepts a run only if it is a `workflow_dispatch` run of the named workflow, on that exact
branch and head SHA, created after `prepare` started. That also tells it apart from the PR's own
`pull_request` run when `test_ref` is the PR head. It fails closed: a 404/422 from the dispatch
(for example, no `workflow_dispatch` trigger in the PR's CI file), no run, or a timeout (45
minutes) all reject the PR with a message saying why. If the queue run itself is cancelled, a
`cancelled()` step cancels the dispatched runs so they don't hold runners.

B work runs on today's runners and doesn't wait for Plan A. The scratch repo
`Thirdline-LLC/merge-queue-scratch` (private, created for B1, deleted after B4) uses the
`thirdline-pool` group.

- [ ] **B1a. `prepare`:** always push the test branch for state `test`. Done when: on the scratch
      repo, a behind PR, an up-to-date PR and a PR whose merge ref is stale each get a branch at
      the expected SHA.
- [ ] **B1b. `merge-queue-wait.yml`:** dispatch, follow, guard, cancel. Done when, on the scratch
      repo: pass merges; failing tests reject; a CI file without `workflow_dispatch` rejects with
      that reason; `gh workflow run` printing no run URL (old gh) fails with a message naming the
      gh version; a dispatch that never starts a run times out and rejects; cancelling the queue
      run cancels the CI run; a PR pushed to mid-test is rejected (head moved).
- [ ] **B1c. `finish`:** delete the branch and its caches. Done when: after a scratch run,
      `gh cache list --ref refs/heads/merge-queue/test-...` is empty, and a cache key written by a
      test run isn't restored by the next run on `main`.
- [ ] **B2. Concurrency check.** Each consumer's CI `concurrency` group (for example
      `checks-${{ inputs.ref || github.ref }}`) must give every test branch its own group, so two
      queue tests or a queue test and a `main` run never cancel each other. Done when: the group
      for each of the four repos is written in the PR, with a scratch run proving it.
- [ ] **B3. Release v2.0.0** of the shared workflows and template (no `ci` job; a `ci_workflows`
      input), README step 2 rewritten (CI needs a `workflow_dispatch` trigger). Consumers pin v2
      by commit SHA with the version in a comment, like v1.1.0 today; the tag is never moved.
      Done when: actionlint and zizmor are clean, and a different worker than the author installs
      the queue on a fresh scratch branch by following only the README.
- [ ] **B4. Move the repos**, one PR each through its own queue: NFC, build-team, cclp, scholars.
      Not while Plan A's A6/A7 PR for the same repo is open: one CI-file PR per repo at a time.
      Done when: each repo's next queued PR merges through v2, and its log shows CI ran on
      `merge-queue/test-*`.
- [ ] **B5. Clean up.** Remove the `inputs.ref` plumbing from each CI workflow, but keep caches
      read-only on `merge-queue/*` refs (`if: ${{ !startsWith(github.ref, 'refs/heads/merge-queue/') }}`)
      as a second guard. Close "Known limits" item in the README, delete the scratch repo.
      Done when: `grep -rn 'inputs.ref' .github/workflows` is empty in all four repos, zizmor is
      clean, and NFC's 4 `actions/cache-poisoning` CodeQL alerts close.

Order: A1–A5 and B1–B3 can run side by side (B doesn't need the new runners). Then A6a, then
A6/A7 per repo (safe on today's runners because of A6a), A8, A9. B4 per repo after that repo's A6/A7 PR has merged, then B5.
