#!/bin/bash
# build.sh — assemble GREENFIELD (two stages) and pack a bootable Advantage floppy.
#
#   ./build.sh            # assemble stage1 + stage2, build greenfield.nsi
#   ./build.sh run        # ...then boot it in NorthMac (auto-presses RETURN)
#   ./build.sh test       # ...then verify the loader + render a stage-2 canvas
#   ./build.sh scp        # ...then convert to NorthStar MFM flux (greenfield.scp)
#
# Requires: z80asm (brew install z80asm), python3, cc.
# `run` needs NorthMac.app; `scp`/hardware write needs Greaseweazle (`gw`).
set -euo pipefail
cd "$(dirname "$0")"

S1=stage1.asm        # the loader (org 0xC100, PROM boot payload)
S2=greenfield.asm    # the art (org 0x8000, all modes) = stage 2
NSI=greenfield.nsi

echo "==> generating sine table + font"
python3 gen_sintab.py
python3 gen_font.py

echo "==> assembling stage 1 (loader) + stage 2 (art)"
z80asm -o stage1.bin "$S1"
z80asm -o stage2.bin "$S2"

echo "==> building $NSI"
python3 mkdisk.py stage1.bin stage2.bin "$NSI"

case "${1:-}" in
run)
    echo "==> booting in NorthMac (auto-presses RETURN at LOAD SYSTEM)"
    "$(cd .. && pwd)/bin/northmac" --auto-enter "$(pwd)/$NSI"
    ;;
test)
    echo "==> verifying the FDC loader against the real FloppyDiskController model"
    cc -O2 -I../NorthMac test/run_loader.c -o test/run_loader
    test/run_loader stage1.bin "$NSI" stage2.bin
    echo "==> rendering a stage-2 canvas on the real z80 core"
    cc -O2 -I../NorthMac test/run_gf.c -o test/run_gf
    test/run_gf stage2.bin test/fb.raw 70000000 "" 0
    python3 test/render_fb.py test/fb.raw test/greenfield.png --green --full
    echo "    rendered test/greenfield.png"
    ;;
scp)
    echo "==> converting to NorthStar MFM hard-sectored flux"
    gw convert --format northstar.mfm.ds "$NSI" greenfield.scp
    echo "    wrote greenfield.scp — write to a real (hard-sectored) disk with:"
    echo "    gw write --hard-sectors --format northstar.mfm.ds $NSI"
    echo "    (add --drive b if the NorthStar drive is jumpered as unit 1)"
    ;;
esac
