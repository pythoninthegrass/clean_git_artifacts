# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## What this is

Two independent implementations of the same tool: find and remove rebuildable
build artifacts (Rust `target`, Node `node_modules`, Python `.venv`/`venv`)
under a directory tree (default `~/git`), dry-run by default.

- `clean_git_artifacts.sh` — bash + `fd`/`du`/`xargs`, the original/fallback.
- `clean_git_artifacts.zig` — Zig rewrite (`std.Thread.Pool` for parallel
  discovery and sizing), compiled to the `cga` binary.

Both must stay behaviorally equivalent: same flags, same matching rules, same
output format. When changing one, mirror the change in the other unless the
task is explicitly about one implementation only.

## Commands

Requires `task` (go-task), `zig` 0.14.0, and `hyperfine`, all mise-managed —
pinned in the **global** mise config at `~/git/mise_config/config.toml` (not a
repo-local `.mise.toml`). If `zig`/`task`/`hyperfine` aren't resolving on
`PATH` in a given shell, use `mise which <tool>` to get the correct binary.

```bash
task build   # compile clean_git_artifacts.zig -> ./cga (ReleaseFast)
task bench   # hyperfine: bash script vs. ./cga, rebuilds cga first
task clean   # remove ./cga (skipped/no-op if it doesn't already exist)
task         # (default) list available tasks
```

There is no test suite — verify changes by running both implementations
against a real tree and diffing output (matched paths, sizes, total) for
parity, per the "Behavior parity" list below.

Run either implementation directly, e.g.:

```bash
./cga -t ~/code -d                  # delete under ~/code
bash clean_git_artifacts.sh -n      # dry-run (default) under ~/git
```

## Behavior parity (must hold across both implementations)

- Flags: `-t/--dir DIR` (default `~/git`), `-n/--dry-run` (default),
  `-d/--delete`, `-h/--help`.
- Match names: exactly `target`, `node_modules`, `.venv`, `venv` (basename
  match, case-sensitive). A matched directory is **pruned** — never recursed
  into — mirroring `fd --prune`.
- Traversal is capped at `max_depth = 3` (root's immediate children are depth
  1). This exists to keep the scan out of package caches / vendored stub trees
  that nest a coincidentally-matching name many levels down (e.g.
  `.cache/uv/archive-v0/.../typeshed-fallback/stdlib/venv`) — those aren't real
  build artifacts. If matching this against `fd`, remember `fd --max-depth N`
  and the Zig `max_depth` constant count depth the same way (verified
  experimentally, not just from docs).
- Sizing follows `du`'s semantics: allocated disk blocks, not apparent size,
  and symlinks are **not followed** (`AT.SYMLINK_NOFOLLOW` in Zig) — otherwise
  symlink farms like `node_modules/.bin` inflate totals by counting the same
  target repeatedly.
- Output: sorted by size descending, deterministic. Paths are displayed
  tilde-collapsed (`$HOME` → `~`) and truncated from the front (keeping the
  tail, since the matched dir name and its parent are the meaningful part) so
  the full printed line (size + two spaces + path) stays under 130 chars.
  Sizes are human-formatted (`K`/`M`/`G`, `G` at ≥1024M).
- Footer: `Would free approximately <total>. Re-run with -d/--delete to
  delete.` (dry-run) or `Freed approximately <total>.` (delete).

## Zig implementation notes

- `dirDiskUsage`/`statAbsolute`/`walk` in `clean_git_artifacts.zig` are the
  core; `run()` (called from a thin `main()` that swallows `error.BrokenPipe`
  so piping into `head`/`less` doesn't print a spurious error) does arg
  parsing, orchestration, and output.
- Uses `std.heap.c_allocator`, not `GeneralPurposeAllocator` — GPA's
  thread-safe mode serializes every alloc/free behind a global mutex, which
  becomes a bottleneck once the tree walk and sizing fan out across the
  thread pool.
- `fanout_depth` (currently 4) controls how deep the *discovery* walk spawns a
  pool task per subdirectory before falling back to plain recursion — this is
  a different knob from `max_depth` (the traversal limit) and is purely a
  perf/overhead tradeoff, not a correctness boundary. Spawning a task for
  every directory in a large tree makes queue/wakeup overhead dominate; a
  measured depth-limited fan-out beat both "task per directory" and "no
  fan-out at all" in benchmarking.
- The workload is syscall-bound (`sys` time dominates `user` time in
  benchmarks), not CPU-bound — thread-count/allocator tuning has diminishing
  returns once the pool saturates all cores. Don't assume a further Zig
  micro-optimization will meaningfully beat the bash+fd+xargs pipeline; in
  practice they land within noise of each other (`task bench` to check).
- Build must pin `-target aarch64-macos` explicitly (see `taskfile.yml`) —
  Zig 0.14.0's native-target auto-detection breaks libSystem linking on macOS
  versions newer than its bundled SDK metadata.

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
