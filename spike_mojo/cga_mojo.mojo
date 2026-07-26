from std import os
from std.algorithm import parallelize
from std.time import perf_counter_ns

comptime MAX_DEPTH = 3

def is_match(name: String) -> Bool:
    return name == "target" or name == "node_modules" or name == ".venv" or name == "venv"

def walk(path: String, depth: Int, mut matches: List[String]) raises:
    if depth > MAX_DEPTH:
        return
    var entries: List[String]
    try:
        entries = os.listdir(path)
    except:
        return
    for i in range(len(entries)):
        var name = entries[i]
        var full = path + "/" + name
        var st: os.stat_result
        try:
            st = os.lstat(full)
        except:
            continue
        if not os.path.isdir(full):
            continue
        if is_match(name):
            matches.append(full)
            continue  # prune -- do not recurse into a matched dir
        walk(full, depth + 1, matches)

def dir_size_kb(path: String) -> Int:
    var total: Int = 0
    var stack = List[String]()
    stack.append(path)
    while len(stack) > 0:
        var cur = stack.pop()
        var entries: List[String]
        try:
            entries = os.listdir(cur)
        except:
            continue
        for i in range(len(entries)):
            var full = cur + "/" + entries[i]
            try:
                var st = os.lstat(full)
                total += Int(st.st_blocks) * 512
                if os.path.isdir(full) and not os.path.islink(full):
                    stack.append(full)
            except:
                continue
    return total // 1024

def main() raises:
    var target_dir = "/Users/lance/git"
    var t0 = perf_counter_ns()

    var matches = List[String]()
    walk(target_dir, 1, matches)

    var sizes = List[Int]()
    for _ in range(len(matches)):
        sizes.append(0)

    @parameter
    def size_work(i: Int):
        sizes[i] = dir_size_kb(matches[i])

    parallelize[size_work](len(matches))

    var total_kb: Int = 0
    for i in range(len(sizes)):
        total_kb += sizes[i]

    var t1 = perf_counter_ns()
    print("matched:", len(matches), " total_kb:", total_kb, " elapsed_ms:", (t1 - t0) // 1_000_000)
