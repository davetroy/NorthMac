#!/bin/bash
# Build the NS-WSG demo: bootable disk + headless WAV render.
# Needs z80asm, and NSPacMan's stage1.bin/mkdisk.py for the boot disk.
set -euo pipefail
cd "$(dirname "$0")"
PACMAN=/Users/davetroy/Development/Personal/northstar/tools/pacman
z80asm -o wsgtest.bin wsgtest.asm
python3 $PACMAN/mkdisk.py $PACMAN/stage1.bin wsgtest.bin wsgtest.nsi
cc -O2 -I../NorthMac run_wsg.c -o run_wsg
./run_wsg wsgtest.bin wsgtest.wav 64000000
