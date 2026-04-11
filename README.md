# Organization `.github` Repository

This repository defines **organization-wide defaults** for:

- AI-first issue intake and planning
- Pull request standards
- Shared GitHub Actions workflow templates
- Governance docs (security, support, contribution expectations)
- Organization automation (team newsletters + platform drift reports)

If a repo in this organization does not define its own equivalent file/template, these defaults apply automatically.

---

## What this repo currently standardizes

### 1) AI-native intake and implementation flow

- Minimal-text issue templates designed for non-developers
- Explicit AI handling flow:
  1. AI validates issue context quality
  2. AI asks grouped clarification questions until actionable
  3. AI posts a concrete implementation proposal
  4. Human approves proposal
  5. AI begins implementation and opens PR to `dev` (or `main` if no `dev` branch)

See:

- `.github/ISSUE_TEMPLATE/ai-feature-request.yml`
- `.github/ISSUE_TEMPLATE/ai-bug-report.yml`
- `.github/ISSUE_TEMPLATE/ai-ops-task.yml`
- `.github/ISSUE_TEMPLATE/config.yml`

### 2) Standard PR expectations

- AI-linked PR checklist
- Risk + rollout + validation expectations
- Conventional commits reminder

See:

- `.github/PULL_REQUEST_TEMPLATE.md`

### 3) Org-level automation workflows (starter implementations)

- **Newsletter aggregation workflow** (scheduled / manual)
  - Reads `.github/reporting/teams.json`
  - Collects commit activity across mapped repos
  - Flags `CHANGELOG.md` drift
  - Publishes the report as a GitHub Discussion in this repo
  - Uploads workflow artifacts and leaves an alerting stub for later

- **Platform drift workflow** (scheduled / manual)
  - Checks repo hygiene signals across mapped repos
  - Reports file/config drift for workflows, CHANGELOG, CODEOWNERS, SECURITY, Renovate, and Sonar config
  - Publishes the report as a GitHub Discussion in this repo
  - Uploads workflow artifacts and leaves an alerting stub for later

See:

- `.github/workflows/org-newsletter.yml`
- `.github/workflows/platform-drift.yml`

### 4) Reusable workflow templates for repos

- Baseline CI quality gates
- AI implementation orchestration scaffold

See:

- `workflow-templates/baseline-quality-gates.yml`
- `workflow-templates/ai-implementation-runner.yml`

---

## Discussion-first reporting

Reports now publish to **GitHub Discussions** instead of email or a website.

- Team newsletters should publish to an `Announcements` discussion category.
- Platform and standards reports should publish to a `Platform Reports` discussion category.
- Alerting is left as an explicit stub so you can wire Teams, email, or another downstream channel later without changing the report generation flow.

Setup inputs live in:

- `.env.example`
- `.github/reporting/teams.json`
- `docs/DISCUSSION_REPORTING.md`

---

## Recommended next implementation milestones

1. Enable Discussions in this repo or enable organization discussions using this repo as the source repository.
2. Create the `Announcements` and `Platform Reports` discussion categories.
3. Populate `.github/reporting/teams.json` with your real team-to-repo mapping.
4. Copy `.env.example` values into GitHub Actions variables and secrets.
5. Wire the alerting stub to GitHub Teams, email, or another downstream notifier when ready.
6. Wire AI issue triage bot (Copilot/Codex/GitHub App) to enforce clarification loop + proposal gating.
7. Add reusable deployment workflow templates that enforce `dev -> staging -> production` promotion rules.

---

## Repo structure

```text
.github/
  ISSUE_TEMPLATE/
  workflows/
  reporting/
workflow-templates/
.env.example
profile/
  README.md
scripts/
docs/
  DISCUSSION_REPORTING.md
```
