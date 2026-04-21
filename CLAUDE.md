# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is the **organization `.github` repository** for Augmenting Integrations. It defines org-wide GitHub defaults that are inherited across all repositories in the organization. It is **not** an application or service -- it is scaffolding and governance.

The repo provides:
- Issue intake templates (AI-friendly structured forms)
- PR template
- Community health files (CONTRIBUTING, SECURITY, SUPPORT)
- Organization profile content (`profile/README.md`)

## What Does NOT Belong Here

Org reporting, audit automation, privileged tokens, and cross-repo operational workflows live in the extracted `.auto/` project (planned to become its own repo). If something needs broader GitHub token scope or changes faster than community-health defaults, it belongs there.

## Repository Configuration

- **Repo type**: library (`.ai-shell.toml`)
- **Branch strategy**: main-only. Feature branches merge directly to `main`.
- **Commit style**: Conventional Commits required.

## Key Directories

- `.github/ISSUE_TEMPLATE/` -- Single unified AI-intake issue form. One field ("What do you need?"), AI handles triage and classification. Blank issues disabled.
- `profile/README.md` -- Public org profile shown on GitHub.

## AI-Assisted Delivery Workflow

This org uses a specific issue-to-PR flow documented in `CONTRIBUTING.md`:

1. Issue opened -- one free-text field, plain language
2. AI agent (`@copilot` or `@codex`) tagged
3. AI triages, classifies, and asks follow-up questions if needed
4. AI posts a proposal
5. Human explicitly approves
6. AI implements and opens PR
7. CI gates must pass before merge

PRs target `dev` if the repo has one, otherwise `main`.
