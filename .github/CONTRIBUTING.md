# Contributing

This organization uses AI-assisted delivery with strict quality gates.

## Required workflow

1. Open an issue and describe what you need in plain language.
2. Tag `@copilot` or `@codex`.
3. AI triages, classifies, and asks follow-up questions if needed.
4. AI posts a proposal.
5. Human explicitly approves proposal.
6. AI implements and opens PR.
7. CI quality/security/compliance gates must pass before merge.

## Commit style

Use [Conventional Commits](https://www.conventionalcommits.org/).

## Branch targeting

Automation should target `dev` when the repository has a `dev` branch; otherwise `main`.
