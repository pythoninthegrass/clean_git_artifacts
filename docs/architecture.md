# Architecture

Design rationale and behavioral contract shared across the bash, Zig, and
Mojo implementations. For build/run/bench commands, see
[development.md](development.md).

## Behavioral parity

Two implementations are the maintained pair and must stay behaviorally
equivalent — same flags, same matching rules, same output format:

- `clean_git_artifacts.sh` — bash + `fd`/`du`/`xargs`, the original/fallback.
- `clean_git_artifacts.zig` — Zig rewrite (`std.Thread.Pool` for parallel
  discovery and sizing), compiled to `bin/zig/cga`.

When changing one, mirror the change in the other unless the task is
explicitly about one implementation only.

There is also a Mojo port, `spike_mojo/cga_mojo.mojo` — see
[Mojo implementation](#mojo-implementation-evaluated-not-adopted) below.
It is verified byte-for-byte parity (see that section) but is **not** part
of the above mandatory keep-in-sync rule: it's a benchmarked, parked
evaluation, not a permanent third implementation. Only touch it when a task
is explicitly about Mojo.

### Contract

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

## Size cache

Both implementations share an opportunistic on-disk size cache to avoid
redoing a full `du`-equivalent walk on every run:

- Path: `${XDG_CACHE_HOME:-$HOME/.cache}/clean_git_artifacts/cache.tsv`.
- Format: 4-column TSV — `path`, `mtime_sec`, `size_kb`, `cached_at` — one
  row per matched directory. Interoperable across implementations: write
  with one binary, read with another, identical results.
- Invalidation: a cached entry is used only if the matched directory's
  mtime is unchanged **and** `now - cached_at < 300` seconds (5-minute
  TTL). The TTL exists to bound a known blind spot — a build tool can
  overwrite an existing file in place, changing size without touching the
  parent directory's mtime, and mtime-only invalidation would miss that
  indefinitely.
- Escape hatch: `NO_CACHE=true` bypasses the cache entirely, forcing a
  fresh walk. Use this for accurate one-off runs and for benchmarking (a
  warm cache measures process/fork overhead, not the sizing logic — see
  [development.md](development.md#benchmarking-notes)).

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

## Mojo implementation (evaluated, not adopted)

`spike_mojo/cga_mojo.mojo` is a hardened Mojo port with full behavioral
parity to `clean_git_artifacts.zig`: same flags, matching rules, `du`-style
block sizing with no-follow symlinks, output format (sort/truncate/tilde
collapse/footer strings), delete path, and the same on-disk cache TSV
(interoperable — write with one binary, read with another, identical
results). Verified via `NO_CACHE=true` diff against `bin/zig/cga` over a
real `~/git` tree: output is identical except for one pre-existing
equal-size sort tie-break ordering quirk that already differs bash vs. zig
(insertion order of same-size matches during discovery differs per
implementation's walk order — not a regression, not resolved, same
tolerance the bash/zig pair already has). `-h`/error/warning output was also
fixed to go to stderr (matching Zig's `std.debug.print`) with exit codes
verified identical.

Build/bench it with `task build:mojo` / `task bench` (installs via
`uv pip install mojo --prerelease allow --system` under the mise-managed
Python; `mojo --version` -> Mojo 1.0.0b2).

**Recommendation: do not adopt Mojo as a permanent third implementation
yet, but the gap has nearly closed** — Mojo's `parallelize` (from
`std.algorithm`) *can* fan the discovery walk itself out, not just the
sizing pass: nested `parallelize` calls (a worker's callback calling
`parallelize` again on its own subdirectories) run genuinely concurrently
with no deadlock, confirmed both with a synthetic sleep-based test and by
rewriting `walk()` in this file to recurse via `parallelize` at every level
(`max_depth` is only 3, so no separate fanout-depth cutoff is needed —
every level fans out, matching Zig's `fanout_depth(4) > max_depth(3)` which
has the same effect). Each parallel branch writes to its own slot of a
`List[List[String]]` and results are merged after `parallelize` returns,
avoiding any lock.

Profiling (a scratch instrumented copy, not committed) after the fan-out
fix showed discovery walk was down to 55-440ms, but sizing
(`dir_disk_usage`) still took ~1.5s of a ~2.0s total run — the dominant
remaining cost, not discovery. The cause: `std.os.listdir()`'s public API
forces a separate `isdir`/`islink` stat() call per file just to determine
type, on top of the `lstat()` needed for `st_blocks`. Mojo's own stdlib
(`os.mojo`'s private `_DirHandle`) already makes a raw `opendir`/`readdir`
FFI call internally and reads each dirent's `d_type` byte (file type
straight from the kernel, no extra syscall) — but discards it, returning
only names. `list_dir_typed()` in `cga_mojo.mojo` mirrors that same FFI
call (macOS `dirent` layout, `external_call["opendir"/"readdir"/"closedir"]`)
but keeps `d_type`, so `walk()` and `dir_disk_usage()` can skip the
redundant stat() call for the common case (known dir/link/regular-file
types), falling back to the old stat-based check only when `d_type` is
`DT_UNKNOWN` (e.g. some filesystems don't populate it).

This closed nearly all of the remaining gap: two reproducible
`NO_CACHE=true task bench` runs (10-run hyperfine each) went from Mojo
~1.6-1.9x slower than Zig to **~1.06-1.10x slower than Zig, and ~1.3-1.4x
faster than bash** — Mojo is now competitive with Zig, within noise on some
runs, and clearly ahead of the bash+fd+xargs pipeline. Verified via
`NO_CACHE=true` diff against `bin/zig/cga` over a real `~/git` tree
(output identical apart from the pre-existing equal-size sort tie-break
quirk) and a synthetic delete-path test with a symlink inside a matched
`node_modules`, confirming the type-skip logic doesn't change delete or
sizing correctness.

Python interop (`from python import Python`) was checked directly —
confirmed unavailable in this install (`mojo` 1.0.0b2 via
`uv pip install mojo --prerelease allow --system`): compiling a file with
that import fails with "unable to locate module 'python'", and no `python`
submodule exists anywhere under site-packages/modular. Public claims that
the full `mojo` PyPI package bundles Python interop don't hold for this
specific beta build.

Recommendation still stops short of "adopt" because: it's now a near-tie
with Zig rather than a clear win, the `list_dir_typed` FFI code is
macOS-specific (mirrors a private, unstable stdlib internal — could break
on a future Mojo release) and unverified on Linux, and Mojo 1.0.0b2 beta
still has real ergonomic gaps: no epoch wall-clock call (`std.time` is
monotonic-only — this port stats a freshly-written marker file as a
workaround, though `sys.ffi.external_call["time", Int64](0)` was confirmed
to work cleanly and is a low-risk fix not yet applied), no `str.format()`
precision specifiers (float formatting for `format_kb` had to be
reimplemented with integer arithmetic), and `Dict`/`String` value access
requires explicit `.copy()` / `^`-transfer bookkeeping. But the performance
case against Mojo that justified "do not adopt" in earlier rounds no longer
holds — this is now much closer to a genuine three-way tie than a clear
Zig/bash win, and worth re-evaluating if a future task wants to push
further (e.g. replacing `epoch_now`'s marker-file hack with the confirmed
FFI `time()` call, or testing `list_dir_typed` on Linux).
