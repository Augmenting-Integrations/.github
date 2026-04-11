# Organization `.github` Repository

This repository defines **organization-wide defaults** for:

- AI-first issue intake and planning
- Pull request standards
- Shared GitHub Actions workflow templates
- Governance docs (security, support, contribution expectations)
- Organization automation (newsletter + standardization audits)

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
  - Groups repos by configured team map
  - Reads commit history + detects `CHANGELOG.md` updates
  - Produces a markdown report artifact
  - Optional: upload to S3 + email delivery hook

- **Standardization audit dry-run workflow** (scheduled / manual)
  - Runs periodic checks to measure repo alignment with your standards
  - Produces JSON + markdown artifacts

See:

- `.github/workflows/org-newsletter.yml`
- `.github/workflows/org-standardization-audit.yml`

### 4) Reusable workflow templates for repos

- Baseline CI quality gates
- AI implementation orchestration scaffold

See:

- `.github/workflow-templates/baseline-quality-gates.yml`
- `.github/workflow-templates/ai-implementation-runner.yml`

---

## SonarQube vs your existing pipelines

Short answer: **do not replace your existing pipelines with SonarQube**.

Use SonarQube as an **additional static quality lens**, not as a pipeline replacement.

- Keep existing status checks for lint/build/test/security/license/acceptance because they validate runtime and delivery behavior.
- Add SonarQube for deeper code-quality metrics (maintainability, hotspots, coverage trends, duplication, issue triage).
- Gate merges on SonarQube quality gates only after calibration, to avoid blocking on noisy defaults.

Suggested layering:

1. Existing CI/CD quality and security gates (required)
2. SonarQube scan and quality gate (initially informational)
3. Promote SonarQube gate to required after baseline tuning per language stack

---

## Recommended next implementation milestones

1. Configure org secrets/variables for newsletter delivery:
   - AWS role to assume
   - S3 bucket/prefix
   - SMTP or SES integration details
2. Build a `teams.yaml` map for repo-to-team grouping
3. Wire AI issue triage bot (Copilot/Codex/GitHub App) to enforce clarification loop + proposal gating
4. Add reusable deployment workflow templates that enforce `dev -> staging -> production` promotion rules
5. Add branch-aware PR target logic (`dev` if exists else `main`) in automation bot

---

## Repo structure

```text
.github/
  ISSUE_TEMPLATE/
  workflows/
  workflow-templates/
profile/
  README.md
```
