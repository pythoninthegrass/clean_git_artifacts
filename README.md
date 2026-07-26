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
