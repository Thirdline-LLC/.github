# Merge queue

A small merge queue built on GitHub Actions. GitHub's own merge queue needs Enterprise Cloud for
private repos, and we don't have it.

You add the label `merge-queue` to a PR. The queue tests the PR merged into the latest `main`,
then squash-merges it. It takes one PR at a time, oldest label first. Nobody has to press
"Update branch" and wait for CI again.

## Using it

Queue a PR:

```bash
gh pr edit N --add-label merge-queue
```

Take it out of the queue: remove the label. If the queue is already testing it, it stops before
the merge and says so on the PR.

The PR must be open, not a draft, based on `main`, and from a branch in the same repo. Its own
checks may still be running when you queue it. The queue waits for them.

What the queue's comments mean:

| Comment | Meaning |
|---|---|
| Queued: testing against main `abc1234`. | Tests run on the PR merged into that `main`. |
| Already up to date with main and checks passed. It will merge if nothing changes. | Nothing to re-test. |
| Merged as `abc1234`. | Done. The label is gone. Main's push workflows were started. |
| Testing against main `abc1234` didn't pass: (reason) | The reason says what: CI failed (with the job names), CI didn't finish in time, or the CI file couldn't be started (it needs `workflow_dispatch`). The label is gone. Fix it and queue it again. |
| Testing was cancelled. / The queue run was cancelled. | Someone cancelled the run. The label is gone. Queue it again. |
| The queue hit an error with this PR. | Something broke in the queue itself. The label is gone. Queue it again. |
| The label was removed, so the queue stopped. | Someone took it out of the queue mid-test. |
| This PR conflicts with main. | Merge `main` into the branch, fix the conflict, queue it again. |
| Main moved while testing. Testing again. | Something else reached `main` first. The label stays. Nothing to do. |
| This PR changed while testing. Testing again. | Someone pushed to the PR. The label stays. Nothing to do. |
| A required check failed on this PR. | The PR's own checks must pass too. Fix them, queue it again. |
| Tests passed against main. GitHub doesn't let the queue merge workflow changes. | Merge it by hand with the command in the comment. See "The workflow token" below. |

## How it works

Each repo has two small workflows. The shared logic lives here, in
`.github/workflows/merge-queue-prepare.yml`, `merge-queue-wait.yml` and `merge-queue-finish.yml`.

1. `merge-queue-kick.yml` runs when a PR gets the label. It starts `merge-queue.yml` on `main`.
   It checks out nothing.
2. `merge-queue.yml` runs one at a time (`concurrency: merge-queue`, never cancelled).
   - **prepare** picks the open PR that got the label first. It ignores which PR started the run.
   - It checks the PR against the current `main`:
     - Up to date with `main` and its required checks are green: state `ready`. No new tests.
     - Behind `main`: it makes a test merge of the PR into the latest `main` and outputs its SHA
       as `test_ref`. State `test`.
     - Doesn't merge cleanly: `conflict`. Draft, closed, wrong base, from a fork, or its own
       checks already failed: `invalid`.
     - For state `test` it pushes the branch `merge-queue/test-<pr>-<run>` at `test_ref` and
       outputs it as `test_branch`.
   - **wait** starts each of this repo's CI files on `test_branch` (`workflow_dispatch`), checks
     that GitHub started exactly that run (event, branch, commit, file, time), and waits for all
     of them. If the queue run is cancelled, it cancels the CI runs it started.
     Because CI runs on its own branch, its caches are that branch's, not `main`'s: a PR can't put
     anything in a cache that `main` later restores.
   - **finish** merges or rejects. Before merging it waits for the PR's own required checks,
     checks that neither `main` nor the PR moved, sets the commit status `merge-queue` to success
     on the PR head, and squash-merges with the head pinned. It then starts the `post_merge`
     workflows on `main`, because merges made with the workflow token don't fire `push`.
   - Each run handles one PR. If more PRs have the label, finish starts the queue again.
   - If a run hits an error, finish takes that PR out of the queue with a comment, then starts
     the queue again for the others. It doesn't restart after its third error in a row.
     If the run fails before it picks a PR, prepare restarts it, with the same limit.
     A run cancelled before its PR leaves the queue doesn't restart: run `merge-queue.yml` by
     hand.
   - A watcher on `workflow_run` can't do this job. GitHub doesn't fire `workflow_run` for runs
     started with the workflow token, and every queue run is.
3. Branch protection requires the `merge-queue` status, so a PR can't merge without the queue.
   "Require branches to be up to date" stays off.

### The test merge

GitHub keeps a test merge for each PR (`refs/pull/N/merge`), but it doesn't refresh it after a
merge made with the workflow token. So after the queue merges one PR, the others' test merges are
stale. prepare uses GitHub's test merge only when its parents are exactly the latest `main` and
the PR head. Otherwise it makes its own: it creates the branch `merge-queue/test-<pr>-<run>` at
`main` and merges the PR head into it with the merges API, then checks the new commit's
parents. Either way CI runs on that branch. finish deletes the branch and its caches, and the
next prepare deletes any that were left behind.

### prepare outputs

| Output | Meaning |
|---|---|
| `pr` | PR number, or empty when nothing is queued |
| `head_sha` | PR head SHA when picked |
| `base_sha` | `main` SHA the test is based on |
| `test_ref` | SHA to test: the test merge, or the PR head when it is already up to date |
| `test_branch` | `merge-queue/test-<pr>-<run>`, at `test_ref`, when state is `test` |
| `state` | `none`, `ready`, `test`, `conflict`, `invalid` or `cancelled` |

Inputs (all optional): `label` (default `merge-queue`), `status_context` (default
`merge-queue`) and `runs_on` (see "Choosing the runner").

### wait inputs and outputs

`test_branch` and `test_ref` from prepare. `ci_workflows`: the CI files to run, space-separated,
for example `checks.yml verify.yml`. `timeout_minutes`: how long to wait for all of them
together (default 45, at most 50). `runs_on` as above. Outputs: `result` (`success` or
`failure`) and, on failure, `reason` (one line).

### finish inputs

`pr`, `head_sha`, `base_sha`, `state`, `test_result` (`success` or `failure`) and
`test_reason` from the caller. Only `success` counts as passed: the template turns a failed,
cancelled or skipped wait into `failure`. `post_merge`: space-separated workflow files to start
on `main` after a merge. `label` and `status_context` and `runs_on` as above.

## Installing it in a repo

Do the file changes in a branch and a PR like any other change.

1. **Add the two caller files** from [`templates/`](templates/) to `.github/workflows/`. In a
   Thirdline-LLC repo you can also pick them in the Actions tab under "New workflow".
   - Leave `merge-queue-kick.yml` as it is.
   - **Pin the three shared workflows to the release commit**, not the tag, and keep the
     version in a comment. Get the commit with
     `gh api repos/Thirdline-LLC/.github/commits/v2.0.0 --jq .sha`, then write each `uses:` as
     `Thirdline-LLC/.github/.github/workflows/merge-queue-prepare.yml@<sha> # v2.0.0`.
   - In `merge-queue.yml`, set `ci_workflows` (in the `wait` job) to every CI workflow file
     that produces a required check, space-separated. If nothing is required yet, list the CI
     files you want a PR to pass before it merges.
   - Keep the template's `permissions: {}` at the top. Write access belongs to `prepare` and
     `finish` only, each with exactly what its shared workflow declares; `wait` gets
     `actions: write` and `contents: read`. A job added later starts with none.
   - Set `post_merge` to the workflows that run on push to `main`. They need a
     `workflow_dispatch` trigger too, because finish starts them that way.
2. **Give each of those CI workflows a `workflow_dispatch` trigger.** Keep every trigger it
   already has. That is the only change it needs: wait starts it on the test branch, where
   `actions/checkout` with no `ref` already checks out the test merge. Things to know:
   - In a queue run, `github.event_name` is `workflow_dispatch`, `github.event.pull_request` is
     empty, `github.ref` is `refs/heads/merge-queue/test-<pr>-<run>` and `github.sha` is the
     test merge. Steps gated on `pull_request` must also run on `workflow_dispatch`. A diff
     against `github.event.pull_request.base.sha` needs a fallback: `HEAD^1` of the test merge
     is the base.
   - A `concurrency` group built from `github.ref` is fine as it is: every test branch is its
     own group, so a queue run and `main`'s runs never cancel each other.
   - The run uses the CI file as the PR changed it, with the repo's secrets, like any push to a
     branch in the repo. Give it a workflow-level `permissions:` block with the least it needs,
     usually `contents: read`.
   - **Caches: the test branch keeps them away from `main`.** A queue run saves caches only in
     its own branch's scope, which finish deletes; `main` never restores them. As a second
     guard, skip cache saves on queue branches: give `actions/setup-node`
     `cache: ${{ !startsWith(github.ref, 'refs/heads/merge-queue/') && 'npm' || '' }}`, split
     `actions/cache` into `actions/cache/restore` plus an `actions/cache/save` step with
     `if: ${{ !startsWith(github.ref, 'refs/heads/merge-queue/') }}`, and give
     `actions/checkout` `persist-credentials: false`.
   - Don't rename jobs. Required check names must still match on normal PR runs.
   - A CI workflow that is also a reusable workflow (`workflow_call` with an input `ref`, from
     v1) still works; the input is just empty. Remove it once no v1 caller is left. A file
     without `workflow_call` must not mention `inputs.ref` at all (actionlint rejects it):
     write `checks-${{ inputs.ref || github.ref }}` as `checks-${{ github.ref }}`.
3. **Settings** (a repo admin does these):
   - Label: `gh label create merge-queue --color 0E8A16 --description "Queued to merge after testing against the latest main"`.
     If the label already exists, keep it; only the name matters.
   - Branch protection on `main`: add `merge-queue` to the required checks, pinned to the GitHub
     Actions app (app id 15368) like the others. Keep "Require branches to be up to date" off
     (`strict: false`). If `main` has no protection yet, add it (or a ruleset with a required
     status check) with `merge-queue` as its only required check. Without it the queue still
     works, but nothing stops a merge that skips it.
   - If a ruleset limits who can create branches, let GitHub Actions create `merge-queue/test-*`.
4. **Check it with a test PR.** Queue a one-line PR. You should see `merge-queue-kick`, then
   `merge-queue`, then "Queued: ..." and "Merged as ..." on the PR, and main's push workflows
   starting.

## Choosing the runner

The queue's jobs run on `ubuntu-latest` unless the repo variable `MERGE_QUEUE_RUNS_ON` says
otherwise. Set it as JSON: a list of labels, or one label in double quotes. A bare word without
the quotes stops every queue run before it starts.

```bash
gh variable set MERGE_QUEUE_RUNS_ON -R OWNER/REPO --body '["self-hosted","my-queue-runner"]'
gh variable set MERGE_QUEUE_RUNS_ON -R OWNER/REPO --body '"my-queue-runner"'   # one label
gh variable delete MERGE_QUEUE_RUNS_ON -R OWNER/REPO   # back to ubuntu-latest
```

The template passes it to prepare, wait and finish as `runs_on`, and `merge-queue-kick.yml`
reads it too. CI itself runs wherever its own `runs-on` says, never on the queue runner. A run reads it when it starts. The runner must be Linux (the scripts need bash 4 or later)
with `gh` and `jq`. If it is offline, queue jobs wait for it (up to a day) and nothing merges:
start it, or delete the variable.

Don't give the queue a runner that also runs PR code. Its jobs hold a token that can merge and
can set the `merge-queue` status. A self-hosted runner keeps its files between jobs, so a PR's
tests, or a package they install, could leave something behind for the next queue job on that
runner. GitHub-hosted runners start clean every time. A self-hosted queue runner needs:

- its own user, with no sudo, whose home no CI user can write;
- a label of its own, named in `MERGE_QUEUE_RUNS_ON`. Every runner also has `self-hosted`, so
  every CI job must ask for a label the queue runner doesn't have;
- `gh`, `jq` and every folder on its `PATH` owned by root.

That keeps out what PR tests leave behind. It doesn't stop someone with write access, who can
point a workflow at any label (see "Known limits"). A runner that takes one job per
registration (`--ephemeral`), or GitHub-hosted, is the stronger choice.

## The workflow token

What the queue's `GITHUB_TOKEN` did in testing, with branch protection pinned to the GitHub
Actions app and a ruleset that requires PRs:

- It merged PRs that change, add or delete files under `.github/workflows/`, and it made test
  merges for them. The "merge it by hand" comment is only a fallback in case GitHub refuses.
- Its `merge-queue` status counts for a check pinned to the GitHub Actions app. A status set with
  a personal token does not, so a person can't skip the queue by setting it by hand.
- Its merge doesn't fire `push` or `pull_request: closed` workflows. That is why finish starts
  the `post_merge` workflows.
- A label added by another workflow's token doesn't fire `merge-queue-kick`. Start the queue
  with `gh workflow run merge-queue.yml --ref main`.

## Known limits

- **The queue stops people, not workflows.** The `merge-queue` check is pinned to the GitHub
  Actions app. A workflow with `statuses: write` on any branch, including a PR's own branch,
  runs as that app and can set the status. Review workflow changes with that in mind. A
  dedicated GitHub App token for the queue would close this, and its merges would also fire
  `push` workflows.
- **CI definitions come from the PR.** The queue runs the CI files as they are on the test
  branch, so a PR that changes CI is tested with its new CI, with the repo's secrets. That is no
  more than a push to any branch in the repo already gets, and the queue takes no forks.
  Review CI changes with that in mind.
- **Last-second pushes.** A push to the PR in the second or two before the merge can be left
  out: GitHub merges the tested head and shows the PR as merged. Open a new PR for the extra
  commit.
- **A hand merge in the last seconds.** If someone merges into `main` between finish's last
  check and its merge, GitHub still merges, untested against that change. Hand merges need the
  `merge-queue` status, so this is rare.
- **One PR at a time.** A repo with long CI and many PRs waits in line. There is no batching.
- **The queue waits up to 30 minutes** for a PR's own required checks. Longer than that, it
  takes the PR out of the queue.
- **Forks aren't supported.** The queue runs PR code in the base repo.
- **Test runs can read `main`'s caches.** GitHub lets any branch restore the default branch's
  caches, so the PR's tests can read them, but they save only into the test branch's scope,
  which the queue deletes. Code in the job could still call the cache service itself, but only
  with that branch's scope. A release or deploy workflow still shouldn't restore caches.
- **Restarts are limited.** After an error the queue restarts itself, but not after its third
  error in a row. An error is a run whose `prepare` or `finish` job failed. A PR whose tests
  failed isn't one. It also doesn't restart when it can't read its own run history, when a run is
  cancelled before its PR leaves the queue, or when a PR keeps its label. Then fix the cause and
  run `merge-queue.yml` by hand. If the label can't be removed, the run fails loudly and the PR
  needs a person.
- **Billing.** Each queue run is a few short jobs, and private repos pay at least a minute per
  job. There is no schedule, so an idle queue costs nothing.
- **Test branches.** Apps that build every branch (preview deploys) will also see the
  `merge-queue/test-*` branches.

## Tested

[Thirdline-LLC/merge-queue-sandbox](https://github.com/Thirdline-LLC/merge-queue-sandbox) is the
test bed for v1. Its PRs show each case: up to date, behind, three at once, two PRs that clash, a
real conflict, a direct merge refused, workflow file changes, and `main` or the PR moving
mid-test.

v2 (CI on the test branch) was tested on a scratch repo: a passing PR merged; failing CI, a CI
file without `workflow_dispatch` and a PR pushed to mid-test were each rejected with the reason;
cancelling the queue run cancelled its CI run; a queue test, a `main` run and a PR run at once
didn't cancel each other; no test branches or caches were left; and a second agent installed
it from this README alone. Details in
[`docs/progress.md`](../docs/progress.md), B1 to B3.
