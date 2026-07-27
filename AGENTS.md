# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## What this is

Find and remove rebuildable build artifacts (Rust `target`, Node
`node_modules`, Python `.venv`/`venv`) under a directory tree (default
`~/git`), dry-run by default. Two maintained implementations
(`clean_git_artifacts.sh`, `clean_git_artifacts.zig`) plus a parked Mojo
evaluation (`spike_mojo/cga_mojo.mojo`) that must stay behaviorally
equivalent to the Zig one but isn't part of the mandatory keep-in-sync rule.

- **[docs/development.md](docs/development.md)** — toolchain, build/run/bench
  commands, how to verify a change (no test suite; diff output against a
  real tree).
- **[docs/architecture.md](docs/architecture.md)** — matching rules and
  rationale, sizing/cache semantics, the behavioral-parity contract, and
  per-implementation notes (Zig, Mojo).

## Context7

Always use Context7 MCP when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.

### Libraries

- mrlesk/backlog.md
- websites/mojolang
- websites/taskfile_dev
- websites/zig_guide

<!-- BACKLOG.MD MCP GUIDELINES START -->

<CRITICAL_INSTRUCTION>

## BACKLOG WORKFLOW INSTRUCTIONS

This project uses Backlog.md MCP for all task and project management activities.

**CRITICAL GUIDANCE**

- If your client supports MCP resources, read `backlog://workflow/overview` to understand when and how to use Backlog for this project.
- If your client only supports tools or the above request fails, call `backlog.get_backlog_instructions()` to load the tool-oriented overview. Use the `instruction` selector when you need `task-creation`, `task-execution`, or `task-finalization`.

- **First time working here?** Read the overview resource IMMEDIATELY to learn the workflow
- **Already familiar?** You should have the overview cached ("## Backlog.md Overview (MCP)")
- **When to read it**: BEFORE creating tasks, or when you're unsure whether to track work

These guides cover:

- Decision framework for when to create tasks
- Search-first workflow to avoid duplicates
- Links to detailed guides for task creation, execution, and finalization
- MCP tools reference

You MUST read the overview resource to understand the complete workflow. The information is NOT summarized here.

</CRITICAL_INSTRUCTION>

<!-- BACKLOG.MD MCP GUIDELINES END -->
