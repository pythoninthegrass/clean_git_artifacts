from std import os

def main() raises:
    var entries = os.listdir(".")
    for i in range(len(entries)):
        print(entries[i])
