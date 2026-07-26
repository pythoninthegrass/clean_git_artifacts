---
id: TASK-001
title: >-
  Harden Mojo spike into a third parity implementation (cga_mojo) for A/B
  benchmarking
status: Done
assignee: []
created_date: '2026-07-26 21:51'
updated_date: '2026-07-26 23:29'
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
modified_files:
  - spike_mojo/cga_mojo.mojo
  - AGENTS.md
  - README.md
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
- [x] #1 Walk parity: match basenames exactly target/node_modules/.venv/venv (case-sensitive), prune matched dirs (no recursion into them), and cap traversal at max_depth = 3 counting depth identically to the bash/zig implementations -- verified experimentally against both, not assumed from docs.
- [x] #2 Sizing parity: du-equivalent block accounting (st_blocks * 512), symlinks not followed (lstat), sizes match the existing two implementations on the same tree.
- [x] #3 Output parity: sorted by size descending (deterministic), tilde-collapsed ($HOME -> ~) paths truncated from the front so the full line (size + two spaces + path) stays under 130 chars, human-formatted sizes (K/M/G, G at >=1024M).
- [x] #4 Footer strings match exactly: dry-run 'Would free approximately <total>. Re-run with -d/--delete to delete.' and delete 'Freed approximately <total>.'
- [x] #5 Flags parity: -t/--dir DIR (default ~/git), -n/--dry-run (default), -d/--delete, -h/--help.
- [x] #6 Shared cache parity: same TSV path (${XDG_CACHE_HOME:-$HOME/.cache}/clean_git_artifacts/cache.tsv) and 4-column format (path, mtime, size_kb, cached_at), mtime + 5-minute TTL invalidation, NO_CACHE=true bypass; cache file is interoperable with both the bash and zig binaries (write with one, read with another, identical results).
- [x] #7 Byte-for-byte dry-run output parity with ./cga verified via diff against a real tree (note: an equal-size sort tie-break ordering quirk already differs bash vs zig -- resolve it across all three or explicitly document it, don't silently regress).
- [x] #8 Tooling: taskfile.yml builds cga_mojo (mojo build) and task bench compares all three implementations (bash, zig, mojo).
- [x] #9 Docs updated: AGENTS.md (currently states 'Two independent implementations' and the parity rule) and README.md reflect the third implementation, extend the keep-in-sync rule to three, and document the Mojo 1.0.0b2 install/version pin plus the parallelize-cannot-raise constraint.
- [x] #10 Delete path (-d) removes matched dirs and evicts their cache entries, matching the other two implementations.
- [x] #11 Task write-up includes a data-backed recommendation on whether the third implementation is worth the ongoing 3-way parity maintenance burden AGENTS.md mandates, rather than silently committing to indefinite upkeep.
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Hardened spike_mojo/cga_mojo.mojo into a single-file, full-parity Mojo port of clean_git_artifacts.zig: flags (-t/-n/-d/-h), match/prune/max_depth=3 rules, du-style block sizing with lstat (no symlink-follow), sorted/tilde-collapsed/truncated output, dry-run and delete footers, delete path (recursive, symlink-safe), and the shared XDG cache.tsv (verified interoperable: write with zig, read with mojo, identical output). Fixed usage/error/warning output to go to stderr (matching Zig's std.debug.print) — verified byte-identical stdout/stderr/exit-code parity for -h, unknown flag, and missing-dir cases. NO_CACHE=true diff against ./bin/zig/cga over a real ~/git tree is identical except one pre-existing equal-size sort tie-break quirk that already differs bash vs. zig (documented, not regressed). Removed the throwaway spike*.mojo scratch files now superseded by the single hardened file.

Recommendation (data-backed, see AGENTS.md "Mojo implementation" section): do NOT adopt Mojo as a permanent third implementation. Two reproducible NO_CACHE=true task bench runs show Mojo ~2.6x slower than Zig and ~1.55x slower than bash — the reverse of the original spike's informal ~1.18x win, which was measured stripped-down and likely under a colder OS page-cache state. Likely cause: this port's discovery walk is single-threaded recursion (Mojo's parallelize only covers sizing), unlike Zig's thread-pool-fanned-out walk. Mojo 1.0.0b2 beta also has real ergonomic gaps: no epoch wall-clock call (worked around by statting a freshly-written marker file), no format-spec float precision (format_kb reimplemented with integer arithmetic), no python interop in this install, and Dict/String access requiring explicit .copy()/^-transfer bookkeeping. Kept cga_mojo.mojo as a working, benchmarked reference, explicitly excluded from the mandatory bash/zig keep-in-sync rule.

Follow-up correction: the initial finding that "Mojo's parallelize only covers sizing, not discovery" was a limitation of this port's original design, not a hard Mojo/stdlib restriction. Confirmed empirically that nested parallelize calls (a worker recursing via parallelize on its own subdirectories) run with genuine multi-core concurrency and no deadlock. Rewrote walk() to fan out recursively at every level (max_depth=3 means no separate fanout-depth cutoff is needed, mirroring Zig's fanout_depth(4) > max_depth(3)), merging per-branch results after parallelize returns (no lock needed). This closed most of the gap: Mojo went from ~2.6x slower than Zig to ~1.6-1.9x slower than Zig (and still marginally slower than bash) across two reproducible NO_CACHE=true task bench runs. Recommendation stands (do not adopt as a permanent third implementation) since it still trails both existing implementations, but the reasoning changes: the remaining gap is likely allocation/Dict/String overhead in the beta stdlib rather than a fundamental inability to parallelize discovery. AGENTS.md and README.md updated with the corrected finding and numbers.

Follow-up (2026-07-26, second round): investigated Python interop and C-stdlib interop per user request. Confirmed Python interop (`from python import Python`) is unavailable in this exact install (mojo 1.0.0b2 via `uv pip install mojo --prerelease allow --system`) — compiling that import fails with 'unable to locate module python', no python submodule anywhere in site-packages/modular, despite public claims the full `mojo` PyPI package bundles it. Confirmed C FFI (`sys.ffi.external_call`) works cleanly for simple libc calls (time() matched wall clock exactly). Profiling showed the walk (after the fan-out fix) was down to 55-440ms, but sizing (dir_disk_usage) still cost ~1.5s of ~2.0s total — the real remaining bottleneck, caused by std.os.listdir()'s public API forcing a redundant isdir/islink stat() per file on top of the lstat() needed for size. Pulled modular/modular's actual os.mojo source and found the stdlib's own private _DirHandle already does a raw opendir/readdir FFI call and reads each dirent's d_type byte (kernel-provided file type, no extra syscall) — but discards it. Implemented list_dir_typed() in cga_mojo.mojo mirroring that same FFI call (macOS dirent layout) while keeping d_type, and updated walk()/dir_disk_usage() to skip the redundant stat() call for known types (falling back to the old stat-based check only for DT_UNKNOWN). Verified: NO_CACHE=true diff against ./bin/zig/cga still identical (same pre-existing tie-break quirk only), plus a synthetic delete-path test with a symlink inside a matched dir confirmed correctness. Result: two reproducible NO_CACHE=true task bench runs went from Mojo ~1.6-1.9x slower than Zig to ~1.06-1.10x slower than Zig, and now ~1.3-1.4x faster than bash (previously slightly slower than bash). This is a much closer three-way race than the original recommendation assumed. Updated AGENTS.md and README.md with the corrected numbers and mechanism. Recommendation still stops short of 'adopt' (near-tie not a clear win, list_dir_typed mirrors an unstable private stdlib internal and is macOS-only/unverified on Linux, plus remaining beta ergonomic gaps), but the performance case against Mojo is now much weaker than previously documented.
<!-- SECTION:FINAL_SUMMARY:END -->
