---
id: TASK-002
title: >-
  Split AGENTS.md into docs/development.md and docs/architecture.md with
  backlinks
status: Done
assignee: []
created_date: '2026-07-26 21:55'
updated_date: '2026-07-26 23:36'
labels:
  - docs
dependencies: []
references:
  - AGENTS.md
modified_files:
  - AGENTS.md
  - README.md
  - docs/development.md
  - docs/architecture.md
priority: low
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
AGENTS.md currently mixes contributor-facing workflow instructions (commands, requirements, mise-pinned toolchain) with design/architecture rationale (matching rules, traversal depth, du/symlink semantics, cache design, Zig implementation notes) in one file. As the project grows a third implementation (see task-001, the Mojo spike hardening work) and the cache/TTL system, this is getting harder to scan. Extract the content into two focused docs under docs/, and keep AGENTS.md as a short entry point that links to them (backlink), so agents and contributors get a quick orientation with a path to deeper detail instead of one long file.

Do not duplicate content between AGENTS.md and the new docs -- move it. AGENTS.md should retain only what an agent needs at a glance (what this repo is, the parity rule, and pointers to the two new docs) plus anything that must stay directly in CLAUDE-facing instructions.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 docs/development.md exists and covers: how to build/run/bench each implementation (bash script, zig binary, mojo binary once task-001 lands), the required toolchain (task, zig 0.14.0, hyperfine, mojo, all mise-managed and pinned in ~/git/mise_config/config.toml), and the `mojo which <tool>` fallback for resolving pinned binaries.
- [x] #2 docs/architecture.md exists and covers: the matching rules and rationale (basename match on target/node_modules/.venv/venv, prune-not-recurse, max_depth=3 and why), du-equivalent sizing semantics (block-based, symlinks not followed), the opportunistic size cache design (shared TSV format, mtime + 5-minute TTL invalidation, NO_CACHE=true escape hatch, known non-guarantee around in-place file overwrites), and the cross-implementation behavioral-parity requirement.
- [x] #3 AGENTS.md is edited to remove the content that moved (no duplication) and instead contains a short overview plus explicit links to docs/development.md and docs/architecture.md.
- [x] #4 Content moved matches current reality -- re-verify each claim (flags, cache TTL value, max_depth, etc.) against the actual source files rather than copying stale prose.
- [x] #5 Links are relative repo paths (e.g. docs/development.md) so they resolve both on GitHub and for local readers.
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Split AGENTS.md into docs/development.md (toolchain, build/run/bench commands, verification method, benchmarking cache-state notes) and docs/architecture.md (matching rules and rationale, du/sizing semantics, size cache design and TTL, bash/zig parity contract, Zig implementation notes, and the full Mojo evaluation writeup/recommendation). AGENTS.md now retains only a short "What this is" overview plus links to both docs, with the Context7/Backlog MCP sections left untouched. README.md's duplicate Mojo/benchmarking sections were replaced with pointers to the same two docs to avoid a third copy of the same content, and its stale `./cga` binary paths were corrected to `bin/zig/cga` (build output moved to bin/{zig,mojo} in an earlier commit but README wasn't updated then). All moved facts (flags, max_depth=3, cache TTL=300s/5min, cache path/format, current Mojo benchmark numbers) were re-verified against clean_git_artifacts.sh, clean_git_artifacts.zig, taskfile.yml, and spike_mojo/cga_mojo.mojo rather than copied as-is. All links are relative repo paths.
<!-- SECTION:FINAL_SUMMARY:END -->
