# Development

Contributor-facing workflow: toolchain, commands, and how to verify a
change. For matching rules, sizing semantics, cache design, and
implementation-specific notes, see [architecture.md](architecture.md).

## Toolchain

Requires `task` (go-task), `zig` 0.14.0, `hyperfine`, and `mojo` (for
`spike_mojo/cga_mojo.mojo`), all mise-managed — pinned in the **global**
mise config at `~/git/mise_config/config.toml` (not a repo-local
`.mise.toml`). If a tool isn't resolving on `PATH` in a given shell, use
`mise which <tool>` to get the correct binary path.

`fd` is also required, but only for `clean_git_artifacts.sh` (the bash
implementation shells out to it).

## Commands

```bash
task build       # build:zig + build:mojo
task build:zig   # compile clean_git_artifacts.zig -> bin/zig/cga (ReleaseFast)
task build:mojo  # compile spike_mojo/cga_mojo.mojo -> bin/mojo/cga
task bench       # hyperfine: bash script vs. bin/zig/cga vs. bin/mojo/cga
task clean       # remove ./bin (skipped/no-op if it doesn't already exist)
task             # (default) list available tasks
```

`bin/` is gitignored — both binaries are build output, not checked in.

Run any implementation directly, e.g.:

```bash
bin/zig/cga -t ~/code -d           # delete under ~/code
bin/mojo/cga -n                    # dry-run (default) under ~/git
bash clean_git_artifacts.sh -n     # dry-run (default) under ~/git
```

## Verifying a change

There is no test suite. Verify changes by running the implementations
against a real tree and diffing output (matched paths, sizes, total) for
parity:

```bash
NO_CACHE=true bin/zig/cga -t ~/git > /tmp/zig_out.txt
NO_CACHE=true bin/mojo/cga -t ~/git > /tmp/mojo_out.txt
diff /tmp/zig_out.txt /tmp/mojo_out.txt
```

`NO_CACHE=true` forces a fresh `du`-equivalent walk on every run, bypassing
the shared size cache — this is the representative comparison for both
correctness diffing and benchmarking (see
[architecture.md](architecture.md#size-cache) for why a warm cache skews
results). One difference tolerated across all three implementations: an
equal-size sort tie-break ordering quirk (insertion order of same-size
matches during discovery differs per implementation's walk order) — not a
regression, not resolved, same tolerance the bash/zig/mojo set already has.

For a change that touches the delete path, also verify against a synthetic
tree (not a real one) containing a symlink inside a matched directory, to
confirm deletion doesn't follow it.

## Deleting artifacts

Both implementations default to a dry run. Nothing is deleted until you
pass `-d`/`--delete`.

**This is destructive and unrecoverable** — deleted directories are not
moved to Trash and cannot be undone. Review the dry-run output first.

```bash
# delete under the default ~/git
bash clean_git_artifacts.sh -d
bin/zig/cga -d

# delete under a different directory
bash clean_git_artifacts.sh -t ~/code -d
bin/zig/cga -t ~/code -d
```

## Benchmarking notes

Both implementations share an opportunistic on-disk size cache
(`~/.cache/clean_git_artifacts/cache.tsv` by default), keyed by each matched
directory's mtime with a 5-minute TTL (see
[architecture.md](architecture.md#size-cache)). This means `task bench`
results depend heavily on cache state:

- **Cold cache** (first run, or after the TTL/mtime invalidates entries):
  all implementations do a full `du`-equivalent walk. This is the
  representative comparison.
- **Warm cache** (repeated runs within the TTL): `du` cost is skipped
  almost entirely, so the benchmark instead mostly measures per-run process
  overhead (`fd`, `stat`, `sort`, `tr`, `awk` for bash vs. a single process
  for zig/mojo). This can show large gaps that don't reflect the underlying
  walk/size logic.

Set `NO_CACHE=true` to bypass the cache entirely and force a fresh walk on
every run, for an apples-to-apples cold-path comparison:

```bash
NO_CACHE=true task bench
```
