# Org Automation Roadmap

## Decisions to finalize

1. **AI agent of record**
   - Copilot, Codex, or both?
   - Which trigger syntax should be canonical?

2. **Proposal acceptance control**
   - Require slash command (`/approve-proposal`) or label-based approval?
   - Who can approve (team leads only vs wider group)?

3. **Auto-merge policy**
   - Allow auto-merge only for low-risk changes?
   - Require manual merge for IaC production-impacting changes?

4. **Discussion publishing contract**
   - Repository discussions only, or organization discussions with this repo as source?
   - Which categories are canonical?
   - Do we want pinned "latest report" index discussions?
   - Which repository is the configured source repository for organization discussions?

5. **SonarQube policy**
   - Which quality gate thresholds by language?
   - Informational-only phase duration before enforcement

## Proposed architecture

- Keep per-repo pipelines as the source of truth for deploy gating.
- Add org-level orchestration from this `.github` repo for consistency checks and reporting.
- Use SonarQube as a supplemental gate integrated into existing CI.
- Use Renovate for dependency hygiene; enforce lockfile + test passing before auto-merge.
- Publish newsletters and platform reports to GitHub Discussions first, then fan out alerts later.

## Implementation phases

### Phase 1

- Roll out issue/PR templates and governance docs (completed in this iteration).
- Roll out starter org workflows for newsletter + standardization audit.

### Phase 2

- Connect workflows to real org repo inventory.
- Add AI summarization and changelog drift detection.
- Add GitHub Teams or other downstream alerting on top of discussion publication.

### Phase 3

- Enforce quality gates with measured thresholds.
- Add policy-as-code for branch protections and required checks.
