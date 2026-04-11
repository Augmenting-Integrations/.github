# Organization `.github` Repository

This repository is the public-facing organization defaults repo.

Its job is to define the things GitHub can inherit or surface organization-wide:

- issue intake templates
- pull request templates
- community health files
- reusable workflow templates
- profile content

It is not the long-term home for privileged operational tooling.

## What belongs here

The files in this repository are intentionally the low-friction, low-privilege defaults that make sense to keep in a public org `.github` repo:

- `.github/ISSUE_TEMPLATE/`
  Minimal, AI-friendly issue intake for feature requests, bugs, and ops tasks.

- `.github/PULL_REQUEST_TEMPLATE.md`
  Standard PR expectations for validation, rollout, and risk communication.

- `.github/CONTRIBUTING.md`
- `.github/SECURITY.md`
- `.github/SUPPORT.md`
  Shared governance and contributor guidance.

- `workflow-templates/`
  Starter workflow templates for repositories in the organization.

- `profile/README.md`
  The organization profile content shown publicly on GitHub.

## What moved out

The org reporting and audit automation has been extracted into `.auto/`.

That split is intentional. The reporting system:

- needs broader GitHub token scope
- benefits from living in a private repo
- changes faster than the community-health defaults
- is operational automation, not GitHub inheritance scaffolding

The extracted project currently lives in:

- `.auto/README.md`
- `.auto/.github/workflows/`
- `.auto/scripts/`
- `.auto/config/`
- `.auto/docs/`

The goal is to lift that directory into its own repository with minimal rework.

## Current structure

```text
.github/
  ISSUE_TEMPLATE/
  CONTRIBUTING.md
  PULL_REQUEST_TEMPLATE.md
  SECURITY.md
  SUPPORT.md
profile/
  README.md
workflow-templates/
.auto/
  README.md
  .github/workflows/
  config/
  docs/
  scripts/
```

## Guidance

If something is primarily about:

- repo defaults
- contributor UX
- org profile presentation
- reusable starter templates

it belongs here.

If something is primarily about:

- org-wide inventory or reporting
- privileged tokens or secret management
- automated standards enforcement
- cross-repo operational workflows

it should live in the extracted automation project instead.
