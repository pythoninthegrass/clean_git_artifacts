from os import listdir
from os.path import isdir, join
from stat import S_ISDIR

fn main() raises:
    var entries = listdir(".")
    for i in range(len(entries)):
        print(entries[i])
