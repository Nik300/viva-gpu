#!/usr/bin/env python3
"""Aggregate the samples of ca's VMG_CA_PROFILE (lines "Tn image+0xoff ...", PC first, then callers).

  prof.py SAMPLES [IMAGE=BINARY ...] [--thread N] [--top K]

IMAGE=BINARY symbolicates that image with atos (e.g. VivaMTLDriver=out/VivaMTLDriver.bundle/VivaMTLDriver); other
images stay image+offset. Prints, per thread with samples outside the kernel's waits, the functions by self time and
by inclusive time (percent of that thread's samples)."""
import collections
import subprocess
import sys


def main():
    args = sys.argv[1:]
    path = args.pop(0)
    bins, thread, top = {}, None, 25
    while args:
        a = args.pop(0)
        if a == '--thread':
            thread = 'T' + args.pop(0)
        elif a == '--top':
            top = int(args.pop(0))
        else:
            k, v = a.split('=', 1)
            bins[k] = v
    samples = [l.split() for l in open(path) if l.strip()]
    # symbolicate every distinct offset of the given images in one atos call per image
    offs = collections.defaultdict(set)
    for s in samples:
        for fr in s[1:]:
            if '+0x' in fr:
                img, off = fr.split('+0x')
                if img in bins:
                    offs[img].add(int(off, 16))
    names = {}
    base = 0x100000000
    for img, os_ in offs.items():
        os_ = sorted(os_)
        out = subprocess.run(['atos', '-o', bins[img], '-l', hex(base)] + [hex(base + o) for o in os_],
                             capture_output=True, text=True).stdout.splitlines()
        for o, n in zip(os_, out):
            n = n.split(' (in ')[0]
            names['%s+0x%x' % (img, o)] = n
    def sym(fr):
        if '+0x' in fr:
            img, off = fr.split('+0x')
            return names.get('%s+0x%x' % (img, int(off, 16)), fr if img in bins else img)
        return fr
    by_thread = collections.defaultdict(list)
    for s in samples:
        by_thread[s[0]].append([sym(f) for f in s[1:]])
    for t, ss in sorted(by_thread.items(), key=lambda kv: -len(kv[1])):
        if thread and t != thread:
            continue
        busy = [s for s in ss if s and s[0] != 'libsystem_kernel.dylib']
        if len(busy) < max(5, len(ss) // 20):
            continue
        print('%s: %d samples, %d busy (%.0f%%)' % (t, len(ss), len(busy), 100.0 * len(busy) / len(ss)))
        self_c = collections.Counter(s[0] for s in ss)
        incl = collections.Counter()
        for s in ss:
            for f in set(s):
                incl[f] += 1
        print('  self:')
        for f, c in self_c.most_common(top):
            print('    %5.1f%%  %s' % (100.0 * c / len(ss), f))
        print('  inclusive:')
        for f, c in incl.most_common(top):
            print('    %5.1f%%  %s' % (100.0 * c / len(ss), f))


if __name__ == '__main__':
    main()
