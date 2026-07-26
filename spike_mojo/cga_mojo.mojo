# Find and remove Rust (target), Node (node_modules), and Python
# (.venv/venv) build artifacts under a directory tree. Dry-run by default.
#
# Mojo port of clean_git_artifacts.zig: same flags, matching rules, sizing
# semantics, output format, and on-disk size cache. See AGENTS.md for the
# shared behavioral-parity contract across bash/zig/mojo.
from std import os
from std import sys
from std.algorithm import parallelize
from std.ffi import c_char, external_call, _CPointer
from std.collections import InlineArray

comptime MAX_DEPTH = 3

# Depth at which the discovery walk stops (root's immediate children are
# depth 1), mirroring `fd --max-depth` / the Zig implementation's max_depth.
# Keeps the scan out of package caches / vendored stub trees that nest a
# coincidentally-matching name many levels down.
def is_match(name: String) -> Bool:
    return name == "target" or name == "node_modules" or name == ".venv" or name == "venv"

# macOS `struct dirent` layout (see modular/modular's stdlib os.mojo,
# _dirent_macos) -- mirrored here so list_dir_typed can read d_type directly
# instead of going through std.os.listdir(), which discards it.
struct _dirent_macos(Copyable):
    comptime MAX_NAME_SIZE = 1024
    var d_ino: Int64
    var d_off: Int64
    var d_reclen: Int16
    var d_namlen: Int16
    var d_type: Int8
    var name: InlineArray[c_char, 1024]

    def __init__(out self):
        self.d_ino = 0
        self.d_off = 0
        self.d_reclen = 0
        self.d_namlen = 0
        self.d_type = 0
        self.name = InlineArray[c_char, 1024](fill=0)

struct DirEntryInfo(Copyable, Movable):
    var name: String
    var d_type: Int8

    def __init__(out self, name: String, d_type: Int8):
        self.name = name
        self.d_type = d_type

comptime DT_UNKNOWN: Int8 = 0
comptime DT_DIR: Int8 = 4
comptime DT_LNK: Int8 = 10

# Lists a directory via raw opendir/readdir (macOS only), returning each
# entry's file-type byte straight from the kernel's dirent alongside its
# name. Mojo's own stdlib os.listdir() makes this exact FFI call internally
# (_DirHandle in os.mojo) but throws d_type away, forcing callers to redo an
# isdir/islink stat() per entry. Keeping d_type lets walk()/dir_disk_usage()
# skip that stat() for the common case (known dir/link/regular-file types),
# falling back to the stat-based check only for DT_UNKNOWN.
def list_dir_typed(path: String) raises -> List[DirEntryInfo]:
    var result = List[DirEntryInfo]()
    var path_c = path
    var handle = external_call[
        "opendir", _CPointer[NoneType, UntrackedOrigin[mut=True]]
    ](path_c.as_c_string_slice().unsafe_ptr())
    if not handle:
        raise Error("opendir failed for " + path)
    var h = handle.value()
    while True:
        var ep = external_call[
            "readdir", _CPointer[_dirent_macos, MutUntrackedOrigin]
        ](h)
        if not ep:
            break
        var d = ep.unsafe_value().take_pointee()
        var name_ptr = d.name.unsafe_ptr().bitcast[Byte]()
        var namelen = 0
        while namelen < _dirent_macos.MAX_NAME_SIZE and Int(name_ptr[namelen]) != 0:
            namelen += 1
        var name_str = String(StringSlice[origin_of(d.name)](
            unsafe_from_utf8=Span[Byte, origin_of(d.name)](
                ptr=name_ptr,
                length=namelen,
            )
        ))
        if name_str == "." or name_str == "..":
            continue
        result.append(DirEntryInfo(name_str, d.d_type))
    _ = external_call["closedir", Int32](h)
    return result^

# Recursively walk `path`, returning every directory whose basename matches
# one of the four match names. A matched directory is pruned -- not
# recursed into -- mirroring `fd --prune` / the Zig walk(). Symlinked
# directories are skipped entirely (not matched, not walked), matching the
# Zig implementation's `entry.kind != .directory` check, which is false for
# a symlink regardless of what it points at.
#
# Fans the walk itself out across the pool via nested `parallelize` calls,
# one call per directory level, mirroring the Zig implementation's
# thread-pool-fanned discovery walk (max_depth is only 3, so this fans out
# at every level rather than needing a separate fanout_depth cutoff). Each
# parallel branch writes only to its own slot of `branch_results`, so no
# lock is needed -- results are merged after `parallelize` returns.
def walk(path: String, depth: Int) -> List[String]:
    var result = List[String]()
    if depth > MAX_DEPTH:
        return result^

    var entries: List[DirEntryInfo]
    try:
        entries = list_dir_typed(path)
    except:
        return result^

    var subdirs = List[String]()
    for i in range(len(entries)):
        var e = entries[i].copy()
        var full = path + "/" + e.name
        var is_link: Bool
        var is_dir: Bool
        if e.d_type == DT_UNKNOWN:
            is_link = os.path.islink(full)
            is_dir = (not is_link) and os.path.isdir(full)
        else:
            is_link = e.d_type == DT_LNK
            is_dir = e.d_type == DT_DIR
        if is_link or not is_dir:
            continue
        if is_match(e.name):
            result.append(full)
            continue
        subdirs.append(full)

    var n = len(subdirs)
    if n == 0 or depth + 1 > MAX_DEPTH:
        return result^

    var branch_results = List[List[String]]()
    for _ in range(n):
        branch_results.append(List[String]())

    @parameter
    def branch(i: Int):
        branch_results[i] = walk(subdirs[i], depth + 1)

    parallelize[branch](n)

    for i in range(n):
        for j in range(len(branch_results[i])):
            result.append(branch_results[i][j])
    return result^

# Recursively sum allocated disk blocks under `path`, in bytes -- matches
# `du`'s block-based accounting (not apparent/logical size). Symlinks are
# not followed (lstat), so symlink farms like node_modules/.bin don't
# inflate totals by counting the same target repeatedly.
def dir_disk_usage(path: String) -> Int:
    var total: Int = 0
    try:
        var st = os.lstat(path)
        total += Int(st.st_blocks) * 512
    except:
        pass

    var entries: List[DirEntryInfo]
    try:
        entries = list_dir_typed(path)
    except:
        return total

    for i in range(len(entries)):
        var e = entries[i].copy()
        var full = path + "/" + e.name
        try:
            if e.d_type == DT_DIR:
                total += dir_disk_usage(full)
            elif e.d_type == DT_UNKNOWN:
                if os.path.islink(full):
                    var st = os.lstat(full)
                    total += Int(st.st_blocks) * 512
                elif os.path.isdir(full):
                    total += dir_disk_usage(full)
                else:
                    var st = os.lstat(full)
                    total += Int(st.st_blocks) * 512
            else:
                # DT_LNK or DT_REG (or any other non-dir type): still needs
                # lstat for st_blocks, but no-follow, matching du semantics.
                var st = os.lstat(full)
                total += Int(st.st_blocks) * 512
        except:
            continue
    return total

def format_kb(kb: Int) -> String:
    if kb >= 1024 * 1024:
        var tenths = (kb * 10 + (1024 * 1024) // 2) // (1024 * 1024)
        var whole = tenths // 10
        var frac = tenths % 10
        return String(whole) + "." + String(frac) + "G"
    elif kb >= 1024:
        var whole = (kb + 512) // 1024
        return String(whole) + "M"
    else:
        return String(kb) + "K"

def pad_left(s: String, width: Int) -> String:
    var out: String = ""
    var n = width - s.byte_length()
    for _ in range(n):
        out += " "
    out += s
    return out

# Collapse a `$HOME`-prefixed absolute path to a `~/...` display form.
def tilde_collapse(path: String, home: String) -> String:
    if path.startswith(home):
        return "~" + path[byte=home.byte_length():]
    return path

# Keeps the printed line (size + two spaces + path) under 130 chars by
# truncating the front of the path, since the meaningful part -- the
# matched dir name and its immediate parent -- is at the end.
comptime PATH_BUDGET = 110

def truncate_path(path: String) -> String:
    if path.byte_length() <= PATH_BUDGET:
        return path
    var keep = PATH_BUDGET - 3
    var start = path.byte_length() - keep
    return "..." + path[byte=start:]

struct CacheEntry(Copyable, Movable):
    var mtime_sec: Int
    var size_kb: Int
    var cached_at: Int

    def __init__(out self, mtime_sec: Int, size_kb: Int, cached_at: Int):
        self.mtime_sec = mtime_sec
        self.size_kb = size_kb
        self.cached_at = cached_at

# A cache hit still expires after this long even if the directory's mtime
# hasn't changed, to bound the blind spot where a build tool overwrites an
# existing file in place (changing size without touching the parent
# directory's mtime).
comptime CACHE_TTL_SEC = 5 * 60

def cache_file_path(home: String) -> String:
    var xdg = os.getenv("XDG_CACHE_HOME", "")
    if xdg.byte_length() > 0:
        return xdg + "/clean_git_artifacts/cache.tsv"
    return home + "/.cache/clean_git_artifacts/cache.tsv"

def load_cache(path: String) -> Dict[String, CacheEntry]:
    var cache = Dict[String, CacheEntry]()
    var contents: String = ""
    try:
        with open(path, "r") as f:
            contents = f.read()
    except:
        return cache^

    var lines = contents.split("\n")
    for i in range(len(lines)):
        var line = lines[i]
        if line.byte_length() == 0:
            continue
        var fields = line.split("\t")
        if len(fields) < 4:
            continue
        try:
            var c_path = String(fields[0])
            var mtime_sec = Int(fields[1])
            var size_kb = Int(fields[2])
            var cached_at = Int(fields[3])
            cache[c_path] = CacheEntry(mtime_sec, size_kb, cached_at)
        except:
            continue
    return cache^

def save_cache(path: String, cache: Dict[String, CacheEntry]) raises:
    var dir_end = path.rfind("/")
    if dir_end >= 0:
        os.makedirs(path[byte=0:dir_end], exist_ok=True)
    var out: String = ""
    for k in cache.keys():
        var e = cache[k].copy()
        out += k + "\t" + String(e.mtime_sec) + "\t" + String(e.size_kb) + "\t" + String(e.cached_at) + "\n"
    with open(path, "w") as f:
        f.write(out)

# Recursively delete `path`, including symlinks encountered along the way
# (removed as links, not followed). Mirrors std.fs.deleteTreeAbsolute.
def delete_tree(path: String) raises:
    if os.path.islink(path):
        os.remove(path)
        return
    if not os.path.isdir(path):
        os.remove(path)
        return
    var entries = os.listdir(path)
    for i in range(len(entries)):
        delete_tree(path + "/" + entries[i])
    os.rmdir(path)

# Epoch seconds "now", derived from a fresh file's mtime -- the Mojo 1.0.0b2
# stdlib exposes no direct wall-clock epoch call (std.time.perf_counter_ns
# is monotonic only), so this stat-a-fresh-file trick stands in for it.
def epoch_now(cache_dir: String) raises -> Int:
    var marker = cache_dir + "/.cga_now"
    os.makedirs(cache_dir, exist_ok=True)
    with open(marker, "w") as f:
        f.write("x")
    var st = os.lstat(marker)
    var now = Int(st.st_mtimespec.tv_sec)
    os.remove(marker)
    return now

def print_usage(prog: String):
    print("Usage: " + prog + " [OPTIONS]", file=sys.stderr)
    print("", file=sys.stderr)
    print("Find and remove Rust (target), Node (node_modules), and Python", file=sys.stderr)
    print("(.venv/venv) build artifacts under a directory tree.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Options:", file=sys.stderr)
    print("  -t, --dir DIR         Directory to scan (default: ~/git)", file=sys.stderr)
    print("  -n, --dry-run         Show what would be deleted without deleting (default)", file=sys.stderr)
    print("  -d, --delete          Actually delete matched directories", file=sys.stderr)
    print("  -h, --help            Show this help message", file=sys.stderr)
    print("", file=sys.stderr)
    print("Environment:", file=sys.stderr)
    print("  NO_CACHE=true         Bypass the size cache; always du fresh", file=sys.stderr)
    print("", file=sys.stderr)
    print("Examples:", file=sys.stderr)
    print("  " + prog + "                 # dry-run under ~/git", file=sys.stderr)
    print("  " + prog + " -d              # delete under ~/git", file=sys.stderr)
    print("  " + prog + " -t ~/code -d    # delete under ~/code", file=sys.stderr)

def main() raises:
    var argv = sys.argv()
    var prog = argv[0]
    var last_slash = prog.rfind("/")
    if last_slash >= 0:
        prog = prog[byte=last_slash + 1:]

    var home = os.getenv("HOME", "")
    if home.byte_length() == 0:
        print("Error: HOME is not set", file=sys.stderr)
        sys.exit(1)

    var target_dir = home + "/git"
    var dry_run = True

    var i = 1
    while i < len(argv):
        var a = argv[i]
        if a == "-t" or a == "--dir":
            i += 1
            if i >= len(argv):
                print("Error: " + a + " requires an argument", file=sys.stderr)
                sys.exit(1)
            target_dir = argv[i]
        elif a == "-n" or a == "--dry-run":
            dry_run = True
        elif a == "-d" or a == "--delete":
            dry_run = False
        elif a == "-h" or a == "--help":
            print_usage(prog)
            return
        else:
            print("Unknown option: " + a, file=sys.stderr)
            print_usage(prog)
            sys.exit(1)
        i += 1

    if not os.path.isdir(target_dir):
        print("Error: directory not found: " + target_dir, file=sys.stderr)
        sys.exit(1)

    var display_dir = tilde_collapse(target_dir, home)

    var matches = walk(target_dir, 1)

    var no_cache = os.getenv("NO_CACHE", "false") == "true"
    var cache_path = cache_file_path(home)
    var cache_dir_end = cache_path.rfind("/")
    var cache_dir = String(cache_path[byte=0:cache_dir_end])

    var cache = Dict[String, CacheEntry]()
    if not no_cache:
        cache = load_cache(cache_path)

    var now = epoch_now(cache_dir)

    var sizes = List[Int]()
    var mtimes = List[Int]()
    for _ in range(len(matches)):
        sizes.append(0)
        mtimes.append(0)

    var needs_compute = List[Int]()
    for idx in range(len(matches)):
        var m = matches[idx]
        try:
            var st = os.lstat(m)
            mtimes[idx] = Int(st.st_mtimespec.tv_sec)
        except:
            pass
        var hit = False
        if not no_cache:
            if m in cache:
                var entry = cache[m].copy()
                if entry.mtime_sec == mtimes[idx] and now - entry.cached_at < CACHE_TTL_SEC:
                    sizes[idx] = entry.size_kb
                    hit = True
        if not hit:
            needs_compute.append(idx)

    @parameter
    def size_work(j: Int):
        var idx = needs_compute[j]
        sizes[idx] = dir_disk_usage(matches[idx]) // 1024

    parallelize[size_work](len(needs_compute))

    if not no_cache:
        for j in range(len(needs_compute)):
            var idx = needs_compute[j]
            cache[matches[idx]] = CacheEntry(mtimes[idx], sizes[idx], now)

    var order = List[Int]()
    for idx in range(len(matches)):
        order.append(idx)

    @parameter
    def cmp(a: Int, b: Int) -> Bool:
        return sizes[a] > sizes[b]

    sort[cmp](order)

    if dry_run:
        print("Dry run: matches under " + display_dir + " (nothing will be deleted)")
        print("")

    var total_kb: Int = 0
    for j in range(len(order)):
        var idx = order[j]
        var path = matches[idx]
        var size_kb = sizes[idx]
        total_kb += size_kb
        var size_human = format_kb(size_kb)
        var display_path = truncate_path(tilde_collapse(path, home))

        if dry_run:
            print(pad_left(size_human, 8) + "  " + display_path)
        else:
            print("Removing " + pad_left(size_human, 8) + "  " + display_path)
            try:
                delete_tree(path)
            except:
                print("warning: failed to delete " + path, file=sys.stderr)
            if not no_cache:
                if path in cache:
                    _ = cache.pop(path)

    if not no_cache:
        try:
            save_cache(cache_path, cache)
        except:
            print("warning: failed to write cache " + cache_path, file=sys.stderr)

    print("")
    var total_human = format_kb(total_kb)
    if dry_run:
        print("Would free approximately " + total_human + ". Re-run with -d/--delete to delete.")
    else:
        print("Freed approximately " + total_human + ".")
