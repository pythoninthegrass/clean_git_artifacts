# clean_git_artifacts

Clean up development detritus under a top-level directory.

## Minimum Requirements

* [zig 0.14.0](https://ziglang.org/download/0.14.0/release-notes.html)
* [fd](https://github.com/sharkdp/fd) (bash script only)
* macOS/Linux

## Recommended Requirements

* [mise](https://mise.jdx.dev/)
* [Taskfile](https://taskfile.dev/)

## Quickstart

```bash
# install runtimes (zig, task, hyperfine) via the pinned mise config
mise install

# build the zig binary (./cga) with taskfile
task build

# run bash script (dry-run, default ~/git)
bash clean_git_artifacts.sh

# run zig binary (dry-run, default ~/git)
./cga

# benchmark bash vs. zig
task bench
```

## Benchmarking notes

Both implementations share an opportunistic on-disk size cache
(`~/.cache/clean_git_artifacts/cache.tsv` by default), keyed by each matched
directory's mtime with a 5-minute TTL. This means `task bench` results depend
heavily on cache state:

* **Cold cache** (first run, or after the TTL/mtime invalidates entries):
  both implementations do a full `du`-equivalent walk. This is the
  representative comparison — currently zig is ~1.24x faster than bash.
* **Warm cache** (repeated runs within the TTL): `du` cost is skipped almost
  entirely for both, so the benchmark instead mostly measures per-run process
  fork overhead (`fd`, `stat`, `sort`, `tr`, `awk` for bash vs. a single
  process for zig). This can show gaps of 7x or more, but it is not a
  reflection of the underlying walk/size logic.

Set `NO_CACHE=true` to bypass the cache entirely and force a fresh walk on
every run, for an apples-to-apples cold-path comparison:

```bash
NO_CACHE=true task bench
```

## Deleting artifacts

Both implementations default to a dry run. Nothing is deleted until you pass `-d`/`--delete`.

**This is destructive and unrecoverable** — deleted directories
are not moved to Trash and cannot be undone.** Review the dry-run output first.

```bash
# delete under the default ~/git
bash clean_git_artifacts.sh -d
./cga -d

# delete under a different directory
bash clean_git_artifacts.sh -t ~/code -d
./cga -t ~/code -d
```
