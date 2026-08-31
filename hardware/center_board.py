#!/usr/bin/env python3
# Shifts a generated board so it sits centered on the sheet for plotting.
# Pads live inside the single footprint (relative coords): shifting the
# footprint origin moves them all; absolute elements are shifted per line.
import re, sys
path, dx, dy = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
out = []
def shift_pair(m):
    return f"({m.group(1)} {float(m.group(2))+dx:.4f} {float(m.group(3))+dy:.4f}"
for line in open(path):
    if '(footprint ' in line:
        line = line.replace('(at 0 0)', f'(at {dx} {dy})')
    elif '(pad ' not in line and re.search(r'\((?:start|end|at)\s', line):
        if any(k in line for k in ('gr_text','gr_line','gr_rect','segment','via','(start','(end','(at')):
            line = re.sub(r'\((start|end|at)\s+(-?[\d.]+)\s+(-?[\d.]+)', shift_pair, line)
    out.append(line)
open(path, 'w').write(''.join(out))
print(f"shifted {path} by ({dx}, {dy})")
