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
the merge.

The PR must be open, not a draft, based on `main`, and from a branch in the same repo. Its own
checks may still be running when you queue it. The queue waits for them.

What the queue's comments mean:

| Comment | Meaning |
|---|---|
| Queued: testing against main `abc1234`. | Tests run on the PR merged into that `main`. |
| Already up to date with main and checks passed: merging. | Nothing to re-test. |
| Merged as `abc1234`. | Done. The label is gone. Main's push workflows were started. |
| Tests failed against main `abc1234`. | The PR breaks on the latest `main`. The label is gone. Fix it and queue it again. |
| This PR conflicts with main. | Merge `main` into the branch, fix the conflict, queue it again. |
| Main moved while testing. Testing again. | Something else reached `main` first. The label stays. Nothing to do. |
| This PR changed while testing. Testing again. | Someone pushed to the PR. The label stays. Nothing to do. |
| A required check failed on this PR. | The PR's own checks must pass too. Fix them, queue it again. |
| Tests passed against main. GitHub doesn't let the queue merge workflow changes. | Merge it by hand with the command in the comment. See "The workflow token" below. |

## How it works

Each repo has two small workflows. The shared logic lives here, in
`.github/workflows/merge-queue-prepare.yml` and `.github/workflows/merge-queue-finish.yml`.

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
   - **This repo's CI** runs as reusable workflows on `test_ref`.
   - **finish** merges or rejects. Before merging it waits for the PR's own required checks,
     checks that neither `main` nor the PR moved, sets the commit status `merge-queue` to success
     on the PR head, and squash-merges with the head pinned. It then starts the `post_merge`
     workflows on `main`, because merges made with the workflow token don't fire `push`.
   - Each run handles one PR. If more PRs have the label, finish starts the queue again.
3. Branch protection requires the `merge-queue` status, so a PR can't merge without the queue.
   "Require branches to be up to date" stays off.

### The test merge

GitHub keeps a test merge for each PR (`refs/pull/N/merge`), but it doesn't refresh it after a
merge made with the workflow token. So after the queue merges one PR, the others' test merges are
stale. prepare uses GitHub's test merge only when its parents are exactly the latest `main` and
the PR head. Otherwise it makes its own: it creates the branch `merge-queue/test-<pr>-<run>` at
`main` and merges the PR head into it with the merges API. finish deletes that branch, and the
next prepare deletes any that were left behind.

### prepare outputs

| Output | Meaning |
|---|---|
| `pr` | PR number, or empty when nothing is queued |
| `head_sha` | PR head SHA when picked |
| `base_sha` | `main` SHA the test is based on |
| `test_ref` | SHA to test: the test merge, or the PR head when it is already up to date |
| `state` | `none`, `ready`, `test`, `conflict` or `invalid` |

Inputs (both optional): `label` (default `merge-queue`) and `status_context` (default
`merge-queue`).

### finish inputs

`pr`, `head_sha`, `base_sha`, `state` and `test_result` (`success` or `failure`) from the
caller. `post_merge`: space-separated workflow files to start on `main` after a merge. `label` and
`status_context` as above.

## Installing it in a repo

Do the file changes in a branch and a PR like any other change.

1. **Add the two caller files** from [`templates/`](templates/) to `.github/workflows/`. In a
   Thirdline-LLC repo you can also pick them in the Actions tab under "New workflow".
   - Leave `merge-queue-kick.yml` as it is.
   - In `merge-queue.yml`, add one job per CI workflow file that produces a required check,
     named after the file, and list each job in `finish.needs`.
   - Set `post_merge` to the workflows that run on push to `main`.
2. **Change each of those CI workflows**, and each one that runs on push to `main`:
   - Add a `workflow_call` trigger with a string input `ref` (default `''`), and
     `workflow_dispatch`. Keep every trigger it already has.
   - Give every `actions/checkout` step `ref: ${{ inputs.ref }}`. If it already sets `ref`,
     use `${{ inputs.ref || <old expression> }}`.
   - **Add a workflow-level `permissions:` block with the least it needs**, usually
     `contents: read`. A called workflow otherwise gets the queue's write token, and the queue
     runs PR code with it.
   - In a called run, `github.event_name` is `workflow_dispatch`, `github.event.pull_request` is
     empty, and `github.ref` and `github.sha` are main's. Steps gated on `pull_request` must also
     run when `inputs.ref != ''`. A diff against `github.event.pull_request.base.sha` needs a
     fallback: `HEAD^1` of the test merge is the base.
   - A `concurrency` group built from `github.ref` or `github.workflow` must include
     `inputs.ref`, so a queue run never cancels main's runs.
   - Don't rename jobs. Required check names must still match on normal PR runs.
   - The queue passes `secrets: inherit`.
3. **Settings** (a repo admin does these):
   - Label: `gh label create merge-queue --color 0E8A16 --description "Queued to merge after testing against the latest main"`.
   - Branch protection on `main`: add `merge-queue` to the required checks, pinned to the GitHub
     Actions app (app id 15368) like the others. Keep "Require branches to be up to date" off
     (`strict: false`).
   - If a ruleset limits who can create branches, let GitHub Actions create `merge-queue/test-*`.
4. **Check it with a test PR.** Queue a one-line PR. You should see `merge-queue-kick`, then
   `merge-queue`, then "Queued: ..." and "Merged as ..." on the PR, and main's push workflows
   starting.

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

- **Any workflow in the repo can set the status.** A workflow with `statuses: write` sets a
  `merge-queue` status that counts, so pinning stops people, not workflows. Review workflow
  changes with that in mind.
- **CI definitions come from `main`.** The queue runs the CI workflow files on `main`, not the
  PR's copy. A PR that changes CI is tested with the old CI.
- **Last-second pushes.** A push to the PR in the second or two before the merge can be left
  out: GitHub merges the tested head and shows the PR as merged. Open a new PR for the extra
  commit.
- **A hand merge in the last seconds.** If someone merges into `main` between finish's last
  check and its merge, GitHub still merges, untested against that change. Hand merges need the
  `merge-queue` status, so this is rare.
- **One PR at a time.** A repo with long CI and many PRs waits in line. There is no batching.
- **The queue waits up to 30 minutes** for a PR's own required checks. Longer than that, it
  takes the PR out of the queue.
- **Forks aren't supported.** The queue runs PR code with the repo's secrets.
- **Errors before a PR is picked** (for example a GitHub outage) fail the run and stop the
  queue. Re-run the failed run or add the label again.
- **Test branches.** Apps that build every branch (preview deploys) will also see the
  `merge-queue/test-*` branches.

## Tested

[Thirdline-LLC/merge-queue-sandbox](https://github.com/Thirdline-LLC/merge-queue-sandbox) is the
test bed. Its PRs show each case: up to date, behind, three at once, two PRs that clash, a real
conflict, a direct merge refused, workflow file changes, and `main` or the PR moving mid-test.
