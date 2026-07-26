from std import os

def main() raises:
    var st = os.lstat(".")
    print(st.st_mtimespec)
