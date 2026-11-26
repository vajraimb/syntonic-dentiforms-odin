# Compares 24 bit uncompressed TGA files, frame by frame, in two directories.
#
# usage: python3 compare_frames.py <reference directory> <other directory>
#
# For every frame of the reference directory that exists in both, it prints:
#   mean   the average, over the pixels, of the largest difference of the
#          three channels (0 to 255)
#   max    the largest of those differences
#   same   the share of pixels that are the same in all three channels
#   within the share of pixels whose largest difference is at most 2
#
# Frames come out of the demo with --capture, and of the F9 key.
import os
import sys


def load(path):
    with open(path, "rb") as f:
        b = f.read()
    if b[2] != 2 or b[16] != 24:
        raise RuntimeError("%s: expected an uncompressed 24 bit TGA" % path)
    w = b[12] | b[13] << 8
    h = b[14] | b[15] << 8
    return b[18:18 + w * h * 3]


def compare(a, b):
    total = 0
    largest = 0
    same = 0
    close = 0
    for i in range(0, len(a), 3):
        d = max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2]))
        total += d
        largest = max(largest, d)
        same += d == 0
        close += d <= 2
    n = len(a) // 3
    return total / n, largest, 100.0 * same / n, 100.0 * close / n


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: python3 compare_frames.py <reference directory> <other directory>")
    ref_dir, other_dir = sys.argv[1], sys.argv[2]
    print("%-8s %9s %5s %8s %8s" % ("frame", "mean", "max", "same", "within"))
    for name in sorted(os.listdir(ref_dir)):
        if not name.endswith(".tga"):
            continue
        other = os.path.join(other_dir, name)
        if not os.path.exists(other):
            print("%-8s missing in %s" % (name[7:12], other_dir))
            continue
        a, b = load(os.path.join(ref_dir, name)), load(other)
        if len(a) != len(b):
            sys.exit("%s: the frames differ in size" % name)
        mean, largest, same, close = compare(a, b)
        print("%-8s %9.3f %5d %7.2f%% %7.2f%%" % (name[7:12], mean, largest, same, close))


if __name__ == "__main__":
    main()
