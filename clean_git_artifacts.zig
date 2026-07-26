// Find and remove Rust (target), Node (node_modules), and Python
// (.venv/venv) build artifacts under a directory tree. Dry-run by default.
//
// Rewrite of clean_git_artifacts.sh: same behavior, sorted output, and a
// thread pool for sizing instead of shelling out to `du`/`xargs` per match.
const std = @import("std");

const match_names = [_][]const u8{ "target", "node_modules", ".venv", "venv" };

const Match = struct {
    path: []const u8, // absolute path, owned
    size_kb: u64 = 0,
};

const Options = struct {
    target_dir: []const u8,
    dry_run: bool = true,
};

fn printUsage(prog: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPTIONS]
        \\
        \\Find and remove Rust (target), Node (node_modules), and Python
        \\(.venv/venv) build artifacts under a directory tree.
        \\
        \\Options:
        \\  -t, --dir DIR         Directory to scan (default: ~/git)
        \\  -n, --dry-run         Show what would be deleted without deleting (default)
        \\  -d, --delete          Actually delete matched directories
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  {s}                 # dry-run under ~/git
        \\  {s} -d              # delete under ~/git
        \\  {s} -t ~/code -d    # delete under ~/code
        \\
    , .{ prog, prog, prog, prog });
}

fn isMatchName(name: []const u8) bool {
    for (match_names) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

const WalkCtx = struct {
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    mutex: *std.Thread.Mutex,
    pool: *std.Thread.Pool,
    wg: *std.Thread.WaitGroup,
};

// Depth (from the scan root) at which we stop spawning a pool task per
// subdirectory and fall back to plain recursion. Spawning a task for every
// directory in the tree (thousands of them) makes queue/wakeup overhead
// dominate; fanning out only across the top few levels (e.g. one task per
// repo under ~/git) gives the same cross-core parallelism `fd`'s walker gets
// without paying per-directory spawn cost for the deep, mostly-small subtrees
// underneath each repo.
const fanout_depth = 4;

// Traversal cap: entries deeper than this (root's immediate children are
// depth 1) are not visited at all, mirroring `fd --max-depth`. Keeps the scan
// out of package caches and vendored stub trees (e.g. `.cache/uv/archive-v0/
// .../typeshed-fallback/stdlib/venv`) that nest a coincidentally-matching
// name many levels down and aren't real build artifacts to clean up.
const max_depth = 3;

// Recursively walk `dir_path` (which this call takes ownership of and frees),
// recording any directory whose basename matches one of match_names. Does not
// recurse into a matched directory (prune), mirroring `fd --prune`. Symlinked
// directories are not followed.
fn walk(ctx: WalkCtx, dir_path: []const u8, depth: u32) void {
    defer ctx.allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        // Permission errors etc. on a subtree shouldn't abort the whole scan.
        std.debug.print("warning: cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (true) {
        const entry = it.next() catch |err| {
            std.debug.print("warning: error reading {s}: {s}\n", .{ dir_path, @errorName(err) });
            break;
        } orelse break;
        if (entry.kind != .directory) continue;
        if (depth + 1 > max_depth) continue;

        const child_path = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.name }) catch continue;

        if (isMatchName(entry.name)) {
            ctx.mutex.lock();
            ctx.matches.append(.{ .path = child_path }) catch {};
            ctx.mutex.unlock();
            continue; // prune: don't recurse into a matched dir
        }

        if (depth < fanout_depth) {
            ctx.pool.spawnWg(ctx.wg, walk, .{ ctx, child_path, depth + 1 });
        } else {
            walk(ctx, child_path, depth + 1);
        }
    }
}

// Recursively sum allocated disk blocks under `path`, in bytes (matches
// `du`'s block-based accounting, not apparent/logical size).
fn dirDiskUsage(allocator: std.mem.Allocator, path: []const u8) !u64 {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        std.debug.print("warning: cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return 0;
    };
    defer dir.close();

    var total: u64 = 0;

    // Size of the directory entry itself.
    if (statAbsolute(path)) |st| {
        total += @as(u64, @intCast(st.blocks)) * 512;
    } else |_| {}

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);

        switch (entry.kind) {
            .directory => total += try dirDiskUsage(allocator, child_path),
            else => {
                const st = statAbsolute(child_path) catch continue;
                total += @as(u64, @intCast(st.blocks)) * 512;
            },
        }
    }

    return total;
}

// AT.SYMLINK_NOFOLLOW matches `du`'s default (no -L): a symlink itself is
// counted (a few bytes), not the target it points to. Without this, symlink
// farms (e.g. node_modules/.bin, pnpm-style linked packages) would have their
// targets' sizes summed in on every occurrence, inflating totals.
fn statAbsolute(path: []const u8) !std.posix.Stat {
    const posix_path = try std.posix.toPosixPath(path);
    return std.posix.fstatatZ(std.posix.AT.FDCWD, &posix_path, std.posix.AT.SYMLINK_NOFOLLOW);
}

const SizeTask = struct {
    allocator: std.mem.Allocator,
    match: *Match,
};

fn sizeWorker(task: SizeTask) void {
    task.match.size_kb = (dirDiskUsage(task.allocator, task.match.path) catch 0) / 1024;
}

fn formatKb(buf: []u8, kb: u64) ![]u8 {
    if (kb >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}G", .{@as(f64, @floatFromInt(kb)) / 1024.0 / 1024.0});
    } else if (kb >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.0}M", .{@as(f64, @floatFromInt(kb)) / 1024.0});
    } else {
        return std.fmt.bufPrint(buf, "{d}K", .{kb});
    }
}

fn matchLessDesc(_: void, a: Match, b: Match) bool {
    return a.size_kb > b.size_kb;
}

// Collapse a `$HOME`-prefixed absolute path to a `~/...` display form, e.g.
// `/Users/lance/git/oth/target` -> `~/git/oth/target`. Falls back to the
// original path if it isn't under `home`.
fn tildeCollapse(buf: []u8, home: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        return std.fmt.bufPrint(buf, "~{s}", .{rest}) catch path;
    }
    return path;
}

// Keeps the printed line (size + two spaces + path) under 130 chars by
// truncating the front of the path, since the meaningful part -- the matched
// dir name and its immediate parent -- is at the end.
const path_budget = 110;

fn truncatePath(buf: []u8, path: []const u8) []const u8 {
    if (path.len <= path_budget) return path;
    const keep = path_budget - 3;
    const start = path.len - keep;
    return std.fmt.bufPrint(buf, "...{s}", .{path[start..]}) catch path;
}

pub fn main() void {
    run() catch |err| {
        // Piping into `head`/`less` and quitting early closes stdout, which
        // surfaces here as BrokenPipe -- that's normal Unix pipe behavior,
        // not a real failure, so exit quietly instead of dumping an error.
        if (err == error.BrokenPipe) return;
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    // GeneralPurposeAllocator serializes every alloc/free behind a global
    // mutex when thread_safe (the default for multi-threaded builds), which
    // becomes a bottleneck once the tree walk and sizing fan out across
    // cores. c_allocator (malloc) scales far better under concurrent use.
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const prog = std.fs.path.basename(args[0]);
    const home = std.posix.getenv("HOME") orelse {
        std.debug.print("Error: HOME is not set\n", .{});
        std.process.exit(1);
    };

    var target_dir_owned: ?[]u8 = null;
    defer if (target_dir_owned) |t| allocator.free(t);

    var opts = Options{ .target_dir = try std.fs.path.join(allocator, &.{ home, "git" }) };
    target_dir_owned = @constCast(opts.target_dir);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: {s} requires an argument\n", .{a});
                std.process.exit(1);
            }
            if (target_dir_owned) |t| allocator.free(t);
            target_dir_owned = try allocator.dupe(u8, args[i]);
            opts.target_dir = target_dir_owned.?;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--delete")) {
            opts.dry_run = false;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage(prog);
            return;
        } else {
            std.debug.print("Unknown option: {s}\n", .{a});
            printUsage(prog);
            std.process.exit(1);
        }
    }

    var dir_check = std.fs.openDirAbsolute(opts.target_dir, .{}) catch {
        std.debug.print("Error: directory not found: {s}\n", .{opts.target_dir});
        std.process.exit(1);
    };
    dir_check.close();

    // Tilde-collapse the target dir for display, same as the bash version.
    var display_buf: [std.fs.max_path_bytes]u8 = undefined;
    const display_dir = tildeCollapse(&display_buf, home, opts.target_dir);

    var matches = std.ArrayList(Match).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit();
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    // Discovery: fan the tree walk itself out across the pool.
    var mutex = std.Thread.Mutex{};
    var walk_wg = std.Thread.WaitGroup{};
    const root_dup = try allocator.dupe(u8, opts.target_dir);
    pool.spawnWg(&walk_wg, walk, .{ WalkCtx{
        .allocator = allocator,
        .matches = &matches,
        .mutex = &mutex,
        .pool = &pool,
        .wg = &walk_wg,
    }, root_dup, 0 });
    pool.waitAndWork(&walk_wg);

    // Sizing: one task per matched dir, in parallel.
    var size_wg = std.Thread.WaitGroup{};
    for (matches.items) |*m| {
        pool.spawnWg(&size_wg, sizeWorker, .{SizeTask{ .allocator = allocator, .match = m }});
    }
    pool.waitAndWork(&size_wg);

    std.sort.block(Match, matches.items, {}, matchLessDesc);

    const stdout = std.io.getStdOut().writer();

    if (opts.dry_run) {
        try stdout.print("Dry run: matches under {s} (nothing will be deleted)\n\n", .{display_dir});
    }

    var total_kb: u64 = 0;
    var size_buf: [32]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (matches.items) |m| {
        total_kb += m.size_kb;
        const size_human = try formatKb(&size_buf, m.size_kb);
        const tilde_path = tildeCollapse(&path_buf, home, m.path);
        var trunc_buf: [std.fs.max_path_bytes]u8 = undefined;
        const display_path = truncatePath(&trunc_buf, tilde_path);

        if (opts.dry_run) {
            try stdout.print("{s:>8}  {s}\n", .{ size_human, display_path });
        } else {
            try stdout.print("Removing {s:>8}  {s}\n", .{ size_human, display_path });
            std.fs.deleteTreeAbsolute(m.path) catch |err| {
                std.debug.print("warning: failed to delete {s}: {s}\n", .{ m.path, @errorName(err) });
            };
        }
    }

    var total_buf: [32]u8 = undefined;
    const total_human = try formatKb(&total_buf, total_kb);

    try stdout.print("\n", .{});
    if (opts.dry_run) {
        try stdout.print("Would free approximately {s}. Re-run with -d/--delete to delete.\n", .{total_human});
    } else {
        try stdout.print("Freed approximately {s}.\n", .{total_human});
    }
}
