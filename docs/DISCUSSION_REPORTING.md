# Discussion Reporting

This repo uses **GitHub Discussions as the single publication surface** for newsletters and platform reports.

## Required setup

1. Enable Discussions for this repository, or enable **organization discussions** and choose this repository as the source repository.
2. Create these discussion categories in the source repository:
   - `Announcements`
   - `Platform Reports`
3. Copy the values from `.env.example` into GitHub Actions variables and secrets.
4. Populate `.github/reporting/teams.json` with your team-to-repo mapping.

## Team map format

```json
{
  "teams": [
    {
      "slug": "woxom",
      "name": "Woxom",
      "discussion_team_mention": "@Augmenting-Integrations/woxom",
      "repos": [
        "repo-one",
        "repo-two"
      ]
    }
  ]
}
```

Notes:

- `repos` can be either short names like `repo-one` or full names like `Augmenting-Integrations/repo-one`.
- `discussion_team_mention` is optional.
- Keep the file in JSON so the workflows can parse it with `jq` without extra dependencies.

## Workflow behavior

### Newsletter

- Runs on a weekly schedule or manual dispatch.
- Collects commits on each repo's default branch for the requested window.
- Counts conventional commit signals for `feat`, `fix`, `perf`, and `refactor`.
- Detects whether `CHANGELOG.md` exists and whether it changed in the same window.
- Publishes the report body to a GitHub Discussion in `Announcements`.

### Platform drift

- Runs on a weekly schedule or manual dispatch.
- Checks for:
  - `README.md`
  - `CHANGELOG.md`
  - `CODEOWNERS`
  - `SECURITY.md`
  - workflow files under `.github/workflows`
  - Renovate config
  - Sonar config
- Publishes the report body to a GitHub Discussion in `Platform Reports`.
- Leaves branch protections, rulesets, deployment guards, and auto-merge checks for the next iteration.

## Alerting stub

Both workflows stop after discussion publication and generate an `alerting-stub.md` artifact. That stub is the hook point for future Teams/email/webhook delivery without changing the reporting contract.

## Suggested GitHub Teams subscriptions

Examples:

- Team channels: subscribe to `.github` discussions.
- Personal app: subscribe to `.github` workflows if you want run-level visibility.

Example commands:

```text
@GitHub Notifications subscribe Augmenting-Integrations/.github discussions
@GitHub Notifications subscribe Augmenting-Integrations/.github workflows
```
