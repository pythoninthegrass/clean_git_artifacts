from std import os
from std.algorithm import parallelize

def main() raises:
    var dirs = List[String]()
    dirs.append("/Users/lance/git/clean_git_artifacts")
    dirs.append(".")
    dirs.append("..")

    var sizes = List[Int]()
    for _ in range(len(dirs)):
        sizes.append(0)

    @parameter
    def work(i: Int):
        try:
            var st = os.lstat(dirs[i])
            sizes[i] = Int(st.st_size)
        except:
            sizes[i] = -1

    parallelize[work](len(dirs), 4)

    for i in range(len(dirs)):
        print(dirs[i], sizes[i])
