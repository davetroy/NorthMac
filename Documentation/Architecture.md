# NorthMac Architecture

## Overview

NorthMac is a macOS emulator for the NorthStar Advantage (circa 1982), a Z80-based microcomputer with a unique memory-mapped bitmap display and NorthStar floppy disk controller.

## Tech Stack

- **SwiftUI** for the app shell and toolbar
- **AppKit** (NSView) for low-level display rendering and keyboard capture
- **C Z80 core** (z80.c/z80.h) via Objective-C bridging header
- **CoreGraphics** for bitmap-to-CGImage rendering

## Module Map

```
NorthMac/
  Core/
    EmulatorCore.swift        -- Main orchestrator: Z80 lifecycle, run loop, timing
    MemorySystem.swift        -- 256KB physical RAM, 4 mapping registers, bank switching
    IOSystem.swift            -- I/O port dispatch, status registers, keyboard
    FloppyDiskController.swift -- FDC state machine, NSI image I/O, sector buffer
    DisplaySystem.swift       -- Video RAM -> CGImage rendering, phosphor colors
    KeyboardSystem.swift      -- macOS key event -> 7-bit ASCII mapping
  Bridge/
    z80-bridge.h              -- C bridging header for z80.h
  Views/
    EmulatorDisplayView.swift -- NSViewRepresentable for bitmap display + key capture
  Models/
    DiskImage.swift           -- NSI format detection
  Resources/
    AdvantageBootRom.bin      -- 2KB boot PROM
```

## Z80 Integration

The C Z80 core communicates with Swift via four callback function pointers set on the `z80` struct:

- `read_byte(userdata, addr)` -- memory read via MemorySystem
- `write_byte(userdata, addr, val)` -- memory write via MemorySystem
- `port_in(z80*, port)` -- I/O read via IOSystem
- `port_out(z80*, port, val)` -- I/O write via IOSystem

`Unmanaged.passUnretained(self)` stores the EmulatorCore reference in `z80.userdata`. Callbacks recover it via `Unmanaged<EmulatorCore>.fromOpaque()`.

**Important**: `z80_init()` NULLs all callbacks. Always call it *before* setting them.

## Memory Architecture

256KB physical address space, 16 pages of 16KB each:

| Pages | Physical Address | Contents |
|-------|-----------------|----------|
| 0-3   | 00000-0FFFF     | 64KB Main RAM |
| 4-7   | 10000-1FFFF     | Unused |
| 8-9   | 20000-27FFF     | 20KB Video RAM (display) |
| A-B   | 28000-2FFFF     | Unused video RAM |
| C-F   | 30000-3FFFF     | 2KB Boot PROM (mirrored) |

Four mapping registers select which physical page backs each 16KB logical window:

| Register | Logical Range | Initial (cold boot) |
|----------|--------------|-------------------|
| 0        | 0000-3FFF    | PROM (page 0xE) |
| 1        | 4000-7FFF    | PROM (page 0xE) |
| 2        | 8000-BFFF    | PROM (page 0xE) |
| 3        | C000-FFFF    | PROM (page 0xE) |

After boot ROM runs, standard mapping becomes: Video/Video/PROM/RAM.

## Video RAM Layout

**Column-major**, not row-major:
- High byte of address (addr / 256) = column (0-79)
- Low byte of address (addr % 256) = scanline (0-255)
- Each byte = 8 horizontal pixels, MSB = leftmost
- Visible area: 640 x 240 pixels (80 cols x 8px, 240 scanlines)
- Scanline register (port 0x90) provides vertical scroll offset

## I/O Port Map

| Ports     | Device | Notes |
|-----------|--------|-------|
| 00-5F     | I/O Board Slots 1-6 | Active-low addressing |
| 60        | RAM Parity | Returns 0x01 (OK) |
| 70        | Board ID | Per-slot identification |
| 80-83     | Floppy Disk Controller | Data, control, flags |
| 90        | Scan Register | Vertical scroll offset |
| A0-A3     | Memory Mapping | Output only, 4 registers |
| B0        | Display Flag | Clear on read/write |
| C0        | NMI Flag | Clear on write |
| D0        | Status Register 2 | Command-dependent + kbd/ack flags |
| E0        | Status Register 1 | Disk status, keyboard, display |
| F0        | I/O Control Register | Command select, acquire, blank |

## Status Register 2 (port D0) Format

Bits 0-3 depend on I/O Control command. Bits 4-7 are always present:

| Bit | Description |
|-----|------------|
| 0-3 | Command-dependent (sector num, char nibbles, flags) |
| 4   | Auto-Repeat |
| 5   | Character Overrun |
| 6   | Keyboard Data Flag (set when key available) |
| 7   | Command Acknowledge (toggles on each I/O control write) |

The boot ROM's GetChar routine polls bit 6 for keyboard data and uses bit 7 XOR to detect command transitions.

## FDC State Machine

Driven by status register reads (every ~34 Z80 instructions via FLOPPY_PULSE):

```
State 0/15 -> Motor start, sector mark HIGH
State 18   -> Countdown (60 ticks)
State 20   -> Increment sector, mark HIGH
State 30   -> Mark HIGH countdown (5 ticks)
State 35   -> Mark LOW transition
State 40   -> Mark LOW countdown (40 ticks) -> back to 15
State 100  -> Sector read ready (serial data = true)
State 200+ -> Write states
```

## NSI Disk Format

Raw sector data, no headers or CRC. File offset = sector_address * 512.

- **350KB (Q-density)**: 35 tracks x 2 sides x 10 sectors x 512 bytes
- **175KB (D-density)**: 35 tracks x 1 side x 10 sectors x 512 bytes

Sector address: `track * 10 + sector` (side 0) or `((max_tracks*2-1) - track) * 10 + sector` (side 1).

## Sector Buffer Layout

When the boot ROM reads a sector via the FDC:

```
[0]       = 0xFB  (second sync byte, discarded by boot ROM)
[1..512]  = 512 bytes of sector data from NSI file
[513]     = CRC computed over [1..512]
```

The boot ROM reads port 0x81 (sync), then 514 reads from port 0x80: discards [0], processes [1..512] as data with CRC, verifies [513].

## Boot Sequence

1. Cold boot: all mapping registers = PROM, PC = 0x8000
2. PROM offset 0x00: `LD SP, 0x0017`, push registers (writes to PROM = ignored)
3. Map reg[2] to PROM, `JP 0x8021`
4. Delay loops, I/O initialization
5. Map reg[0]/[1] to video RAM, SP = 0x0200
6. Clear video RAM, display "LOAD SYSTEM"
7. Map reg[3] to RAM, map reg[0]/[1] to RAM page 0
8. Wait for keyboard input (polls status reg 2 bit 6)
9. On RETURN: select drive, seek track 0, read boot sectors
10. Verify JP (0xC3) at entry point offset (patched out for compatibility)
11. Jump to loaded code via `JP (HL)`

## Boot ROM Patches

The boot ROM is patched in memory after loading:
- **Offset 0x0189-0x018D**: NOP'd out `CP C3H / JP NZ,806BH`. Some disk images have the JP instruction at a different offset than the boot ROM expects. Removing this check allows any loaded code to execute.

## CP/M BIOS Variants

Two types of NorthStar CP/M BIOS exist:

### Polled I/O BIOS
- Directly reads FDC status/data ports in polling loops
- No interrupt support needed
- Used by: `advf2_cpm120_wm.nsi`, DEMODIAG
- **Works with our emulator**

### Interrupt-Driven BIOS
- Starts FDC operation, enables display interrupt (I/O control bit 7)
- Polls a RAM completion flag that the ISR sets
- Requires Z80 INT delivery and proper ISR setup
- Used by: N2212_64, N22A_56, C145_54, etc.
- **Does not work yet** (see Documentation/Interrupts.md)

## Display System

The NorthStar Advantage has NO character generator hardware. All text rendering is done in software via PROM routines that paint character bitmaps into video RAM. The PROM contains font data (offset ~0x700) and character rendering code (offset ~0x4CD). CP/M's BIOS calls these PROM routines for console output.
