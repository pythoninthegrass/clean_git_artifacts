---
id: TASK-001
title: >-
  Harden Mojo spike into a third parity implementation (cga_mojo) for A/B
  benchmarking
status: To Do
assignee: []
created_date: '2026-07-26 21:51'
labels:
  - performance
  - mojo
  - spike
dependencies: []
references:
  - spike_mojo/cga_mojo.mojo
  - spike_mojo/
documentation:
  - AGENTS.md
  - README.md
  - 'https://mojolang.org/docs/'
  - 'https://docs.modular.com/mojo/std/algorithm/functional/parallelize/'
priority: low
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A Mojo spike (spike_mojo/cga_mojo.mojo) beat the tuned Zig binary by ~1.18x on a cold, no-cache full walk over ~/git (10-run hyperfine: mojo 3.105s vs zig 3.662s vs bash 3.970s). That's a real enough signal to make Mojo a credible third implementation, but the spike is not production-ready: it only prints match-count/total-KB and has none of the output formatting, flags, delete path, or shared cache that clean_git_artifacts.sh and clean_git_artifacts.zig have, so it has never gone through a fair, output-parity task bench. This task is to harden the spike up to full behavioral parity with the existing two implementations so it can be benchmarked fairly, and to make an informed (not pre-decided) call on whether Mojo earns a permanent place alongside bash/zig.

Handoff facts for whoever picks this up (Mojo 1.0.0b2 beta diverges sharply from published docs, discovered empirically this session):
- Installed via `uv pip install mojo --prerelease allow --system`; resolves under the mise-managed python (`mojo --version` -> Mojo 1.0.0b2).
- `fn` is removed -- use `def`; raising calls need `def ... raises`.
- `alias` is deprecated -- use `comptime`.
- stdlib is one `std` package: `from std import os`, `from std.algorithm import parallelize`, `from std.time import perf_counter_ns` (NOT top-level `os`).
- `os.lstat` exists (no-follow); `stat_result` has `st_mtimespec` (ns duration), `st_size`, `st_blocks`. `os.path.isdir` / `os.path.islink` work.
- `parallelize`'s callback type is `def(Int) capturing -> None` and CANNOT `raises` -- the raising `os.stat`/`listdir`/`lstat` calls must be wrapped in try/except inside the closure with no error propagation out. This is a real ergonomics gap vs. Zig's typed error unions (no clean local-vs-fatal error distinction).
- `parallelize[func](num_work_items, num_workers)` overload gives explicit concurrency control.
- `List[T]` literal constructor with positional args is rejected -- build lists with `.append()`.

Reference: spike_mojo/cga_mojo.mojo (and other scratch spike*.mojo files in spike_mojo/) contain the working recursive walk + prune-on-match + lstat sizing + parallelize fan-out logic from this session -- reuse/extend rather than starting over.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Walk parity: match basenames exactly target/node_modules/.venv/venv (case-sensitive), prune matched dirs (no recursion into them), and cap traversal at max_depth = 3 counting depth identically to the bash/zig implementations -- verified experimentally against both, not assumed from docs.
- [ ] #2 Sizing parity: du-equivalent block accounting (st_blocks * 512), symlinks not followed (lstat), sizes match the existing two implementations on the same tree.
- [ ] #3 Output parity: sorted by size descending (deterministic), tilde-collapsed ($HOME -> ~) paths truncated from the front so the full line (size + two spaces + path) stays under 130 chars, human-formatted sizes (K/M/G, G at >=1024M).
- [ ] #4 Footer strings match exactly: dry-run 'Would free approximately <total>. Re-run with -d/--delete to delete.' and delete 'Freed approximately <total>.'
- [ ] #5 Flags parity: -t/--dir DIR (default ~/git), -n/--dry-run (default), -d/--delete, -h/--help.
- [ ] #6 Shared cache parity: same TSV path (${XDG_CACHE_HOME:-$HOME/.cache}/clean_git_artifacts/cache.tsv) and 4-column format (path, mtime, size_kb, cached_at), mtime + 5-minute TTL invalidation, NO_CACHE=true bypass; cache file is interoperable with both the bash and zig binaries (write with one, read with another, identical results).
- [ ] #7 Byte-for-byte dry-run output parity with ./cga verified via diff against a real tree (note: an equal-size sort tie-break ordering quirk already differs bash vs zig -- resolve it across all three or explicitly document it, don't silently regress).
- [ ] #8 Tooling: taskfile.yml builds cga_mojo (mojo build) and task bench compares all three implementations (bash, zig, mojo).
- [ ] #9 Docs updated: AGENTS.md (currently states 'Two independent implementations' and the parity rule) and README.md reflect the third implementation, extend the keep-in-sync rule to three, and document the Mojo 1.0.0b2 install/version pin plus the parallelize-cannot-raise constraint.
- [ ] #10 Delete path (-d) removes matched dirs and evicts their cache entries, matching the other two implementations.
- [ ] #11 Task write-up includes a data-backed recommendation on whether the third implementation is worth the ongoing 3-way parity maintenance burden AGENTS.md mandates, rather than silently committing to indefinite upkeep.
<!-- AC:END -->
