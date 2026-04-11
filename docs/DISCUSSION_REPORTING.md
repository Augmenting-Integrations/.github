# Discussion Reporting

This repo uses **GitHub Discussions as the single publication surface** for newsletters and platform reports.

## Required setup

1. Enable Discussions for this repository, or enable **organization discussions** and choose this repository as the source repository.
2. Create these discussion categories in the source repository:
   - `Announcements`
   - `Platform Reports`
3. Copy the values from `.env.example` into GitHub Actions variables and secrets.
4. Optionally populate `.github/reporting/teams.json` with team metadata overrides.

Important:

- For **organization discussions**, GitHub still uses a **source repository**.
- This workflow publishes through that source repository because GitHub's discussion creation API requires a repository ID and a category ID from that repository.
- Set `REPORTING_DISCUSSION_SOURCE_REPOSITORY` to the repo selected in the organization's Discussions settings.

## Team map format

This file is optional.

- If the file is empty or missing, the newsletter discovers teams via the GitHub API.
- If the file contains teams, those entries act as the allowlist/metadata source, but repository membership is still learned from the GitHub API.
- `repos` entries are no longer required for newsletter discovery.

```json
{
  "teams": [
    {
      "slug": "woxom",
      "name": "Woxom",
      "discussion_team_mention": "@Augmenting-Integrations/woxom"
    }
  ]
}
```

Notes:

- `discussion_team_mention` is optional.
- Keep the file in JSON so the workflows can parse it with `jq` without extra dependencies.

## Workflow behavior

### Newsletter

- Runs on a weekly schedule or manual dispatch.
- Discovers teams and their repositories via the GitHub API.
- Publishes one discussion per team titled `{Team Name} Weekly Update`.
- Collects commits on each repo's default branch for the requested window.
- Counts conventional commit signals for `feat`, `fix`, `perf`, and `refactor`.
- Detects whether `CHANGELOG.md` exists and whether it changed in the same window.
- Adds last-week git history for `dev` (`staging`) and `main` (`production`) branches where they exist.
- Publishes the report body to a GitHub Discussion in `Announcements`.

Notes:

- If `GH_TOKEN` cannot read team metadata or private repositories, the newsletter will only cover what the token can see.
- If you want to restrict the newsletter to a subset of teams while still learning repo membership from GitHub, list those teams in `.github/reporting/teams.json`.

### Platform drift

- Runs on a weekly schedule or manual dispatch.
- Auto-discovers all non-archived repositories in the organization that are visible to `GH_TOKEN`.
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

Notes:

- If `GH_TOKEN` can only see public repositories, the platform drift report will only cover public repositories.
- Team mapping is for the newsletter flow; platform drift is organization-wide by default.
- The current platform drift table is a real presence audit, not yet a deep policy or behavior audit. A green check means the file or config was found in a standard location; it does not yet mean the content is correct or enforced.

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
