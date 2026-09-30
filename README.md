# monowai/.github

Organisation-wide GitHub Actions for the Beancounter repos — the things shared
by several repos, which should not live inside any one of them.

| Workflow | What it does |
|---|---|
| [`build-base-image.yml`](.github/workflows/build-base-image.yml) | Publishes `ghcr.io/monowai/eclipse-temurin`, the shared JRE base image. Runs here. |
| [`ocr-review.yml`](.github/workflows/ocr-review.yml) | Reusable AI code review. Called by each repo. |
| [`mirror-images.yml`](.github/workflows/mirror-images.yml) | Copies third-party images into `ghcr.io/monowai` so builds never pull them anonymously. Runs here, by hand. |

> This repo is **public** so that `beancounter` (also public) can call the
> workflows here without any cross-visibility access configuration. Nothing
> secret lives in it — secrets are passed in by the caller.
>
> There is deliberately no `profile/README.md`; adding one would publish an
> organisation profile page.

## `build-base-image.yml` — shared JRE base image

Builds and publishes **`ghcr.io/monowai/eclipse-temurin`**, the base image every
Beancounter service extends.

Source: [`docker/base/Dockerfile`](docker/base/Dockerfile). It is
`eclipse-temurin:25-jre-alpine` plus the Sentry OpenTelemetry agent and an
`apk upgrade` — Temurin's published tag lags Alpine security bumps, so the
upgrade pulls fixed packages rather than waiting for an upstream rebuild. That
propagates to every service through this one image.

Consumers (unchanged by the move — same image name, same tags):

| Repo | Services |
|---|---|
| `beancounter` | svc-data, svc-position, svc-event, svc-admin, svc-agent |
| `svc-retire` | the service image |
| `svc-rebalance` | the service image |
| `bc-deploy` | `Dockerfile.profiler` (older `21-jre-sentry7` tag) |

It previously lived in `beancounter`, which made a cross-repo artifact look
like one service's private business.

**Triggers:** a push to `main` touching `docker/base/Dockerfile` or the workflow,
or `workflow_dispatch`. Builds `linux/amd64` and `linux/arm64` on native
runners, then stitches a multi-arch manifest for both the versioned tag and
`latest`. The Sentry version in the tag is read out of the Dockerfile, so
bumping `ENV SENTRY_VERSION=` is the whole release process.

**No secret required.** It authenticates with the built-in `GITHUB_TOKEN` plus
`permissions: packages: write` — nothing to store or rotate. (The beancounter
original used a `GH_TOKEN` PAT despite already granting `packages: write`,
which looks like habit rather than necessity.)

One-time setup, though: the `eclipse-temurin` package predates this repo and is
linked to `beancounter`, and an existing package only accepts pushes from repos
listed in its own access settings. Grant this one write, once:

> `ghcr.io/monowai/eclipse-temurin` → Package settings → **Manage Actions
> access** → Add repository → `monowai/.github` → **Write**

Without that grant, the login step succeeds and the push fails with `403
denied` — so a dispatch run is a cheap, safe way to confirm the grant is in
place.

## `mirror-images.yml` — third-party images, mirrored

Copies an image that an estate Dockerfile depends on into `ghcr.io/monowai`.
Today that is **`ghcr.io/monowai/aws-lambda-adapter`**, the AWS Lambda Web
Adapter, which `ruby`'s `docker/Dockerfile` copies in.

The upstream is `public.ecr.aws/awsguru/aws-lambda-adapter`. ECR rations
anonymous pulls per source IP, and GitHub's runners share their IPs, so
`ruby`'s image build failed on `main` with `toomanyrequests: Data limit
exceeded` twice in September 2026 even though its code had not changed. A
mirror in GHCR avoids that.

It lives here rather than in `ruby` because this repo is public, so its runs
cost no Actions minutes. A second service that moves to Lambda will also find
it here.

```bash
gh workflow run mirror-images.yml -R monowai/.github -f version=0.9.1
```

The job summary prints `ghcr.io/monowai/aws-lambda-adapter:<version>@<digest>`.
Consumers pin that digest. Bumping the adapter is two steps: run this with the
new version, then change the tag and digest in the consumer's Dockerfile.
Renovate does not watch the mirror.

The copy pulls from ECR on a GitHub runner, so it can hit the same limit. It
is one pull per version, so re-run it if that happens.

**The package is private.** Only monowai repositories pull it. It is linked
to `monowai/ruby`, because `ruby`'s own copy of this workflow made the first
mirror on 2026-09-30. Access is granted per repository, under
`ghcr.io/monowai/aws-lambda-adapter` → Package settings → **Manage Actions
access**:

| Repository | Access | Why |
|---|---|---|
| `monowai/ruby` | linked | Its image build copies the adapter in. |
| `monowai/.github` | **Write**, not yet granted | Needed before this workflow can push the next version. Without it the copy fails with `denied: permission_denied: read_package`. |

Another repository that starts using the adapter needs **Read** added there
too. On a laptop, run `docker login ghcr.io` with a token that has
`read:packages` before a local build.

## `ocr-review.yml` — AI code review

Runs [OpenCodeReview](https://github.com/alibaba/open-code-review) over a pull
request and posts inline comments plus a sticky summary. Wraps the first-party
composite action; this repo only owns the wiring.

Used by `beancounter`, `bc-view`, `svc-retire` and `svc-rebalance`.

### Calling it

The caller owns the triggers, because `on:` cannot live in a reusable workflow.

```yaml
name: AI Code Review

on:
  pull_request:
    types: [opened, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: "PR number to review"
        required: true
        type: string

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || inputs.pr_number }}
  cancel-in-progress: true

jobs:
  review:
    uses: monowai/.github/.github/workflows/ocr-review.yml@v1
    with:
      pr_number: ${{ inputs.pr_number }}
    secrets:
      OCR_LLM_AUTH_TOKEN: ${{ secrets.OCR_LLM_AUTH_TOKEN }}
```

The secret is passed explicitly rather than with `secrets: inherit`, which
would hand every caller secret to a workflow defined in a public repo.

### Why `opened` + `ready_for_review`

Draft means "not finished"; Ready means "this is ready to be looked at". Firing
there puts findings in front of a human *before* they open the PR.

Both event types are needed to mean "when this PR becomes ready", because
neither covers it alone:

| PR is | Event | Result |
|---|---|---|
| opened as a draft | `opened`, `draft: true` | skipped — reviewed later, on promotion |
| promoted draft → ready | `ready_for_review` | **reviewed** |
| opened straight into ready | `opened`, `draft: false` | **reviewed** |

`ready_for_review` only ever fires on the transition, so on its own it silently
skipped every normally-opened PR. The draft filter lives in the shared job's
`if:`, so each PR is still reviewed exactly once on becoming ready.

It is deliberately not on every push. Each run bills a metered LLM account and
the agent reads well beyond the diff — one review of a single 14-line file
measured ~364k tokens and 4m35s.

### Markdown-only PRs are skipped

A PR where every changed file ends in `.md` or `.mdx` has nothing for a code
reviewer to find, so the review step is skipped and the check reports green —
the diff is fine and a skipped check says otherwise. What was skipped, and how
to override it, lands in the run summary.

The test is deliberately narrow. One non-Markdown file puts the whole PR back
in scope, including a script that happens to sit under `docs/`.

If a prose change does warrant a review, dispatch one:

```bash
gh workflow run ocr-review.yml -f pr_number=<N>
```

That is the only exception path — `workflow_dispatch` never applies the skip.
There is no per-repo opt-out, because none of the repos on this workflow wants
its Markdown reviewed.

To re-review after pushing fixes:

```bash
gh workflow run ocr-review.yml -f pr_number=<N>
```

Re-running the original job would re-review the head SHA it first saw, which is
why there is an explicit dispatch path that resolves the current head.
`incremental: true` means a re-run only appends inline comments that do not
overlap existing ones, and never deletes history.

### Inputs

| Input | Default | Notes |
|---|---|---|
| `pr_number` | — | Required for `workflow_dispatch`; empty on `ready_for_review`, where the event payload supplies the refs. |
| `llm_url` | `https://api.deepseek.com/chat/completions` | |
| `llm_model` | `deepseek-v4-pro` | |
| `llm_use_anthropic` | `"false"` | `"true"` selects the Anthropic protocol. |

| Secret | Required |
|---|---|
| `OCR_LLM_AUTH_TOKEN` | yes |

Set the secret once at organisation level so new repos are covered
automatically.

### Versioning

Callers pin `@v1`. To roll a change out to every repo at once, move the `v1`
tag — the same convention `actions/checkout` uses for its major tags:

```bash
git tag -f v1 && git push -f origin v1
```

Breaking changes to the inputs get a `v2` and a deliberate caller migration.
