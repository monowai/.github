# monowai/.github

Organisation-wide GitHub Actions for the Beancounter repos — the things shared
by several repos, which should not live inside any one of them.

| Workflow | What it does |
|---|---|
| [`build-base-image.yml`](.github/workflows/build-base-image.yml) | Publishes `ghcr.io/monowai/eclipse-temurin`, the shared JRE base image. Runs here. |
| [`ocr-review.yml`](.github/workflows/ocr-review.yml) | Reusable AI code review. Called by each repo. |

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

**Requires the `GH_TOKEN` secret** — a PAT with `write:packages`. `GITHUB_TOKEN`
is not used: the `eclipse-temurin` package predates this repo and is linked to
`beancounter`, so a repo-scoped token from here is not guaranteed write access.

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
    types: [ready_for_review]
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

### Why `ready_for_review`

Draft means "not finished"; Ready means "this is ready to be looked at". Firing
there puts findings in front of a human *before* they open the PR.

It is deliberately not on every push. Each run bills a metered LLM account and
the agent reads well beyond the diff — one review of a single 14-line file
measured ~364k tokens and 4m35s.

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
