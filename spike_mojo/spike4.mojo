from std import os

def main() raises:
    var st = os.stat(".")
    print(st.st_mtimespec)
