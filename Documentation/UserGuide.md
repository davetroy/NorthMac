# NorthMac User Guide

## Getting Started

1. Open `NorthMac.xcodeproj` in Xcode
2. Build and Run (Cmd+R)
3. The emulator starts automatically with a disk mounted
4. Click the emulator display to give it keyboard focus
5. Press **RETURN** when "LOAD SYSTEM" appears to boot from Drive 1

## Controls

### Toolbar

| Control | Description |
|---------|------------|
| **Stop/Start** | Pause or resume the Z80 CPU (Cmd+R) |
| **Reset** | Cold reboot the emulator (Cmd+Shift+R) |
| **Drive 1** | Select a .NSI disk image for floppy drive 1 |
| **Drive 2** | Select a .NSI disk image for floppy drive 2 |
| **Phosphor** | Display color: Green, Amber, or White |
| **Turbo** | Run at maximum host speed (no 4MHz throttle) |
| **Screenshot** | Save the current display as a PNG file |

### Keyboard

Standard ASCII keys map directly. Special keys:

| Mac Key | Advantage Key |
|---------|--------------|
| Return | RETURN (0x0D) |
| Tab | TAB (0x09) |
| Delete | Backspace (0x08) |
| Escape | ESC (0x1B) |
| Arrow keys | Cursor control |
| Ctrl+letter | Control codes |

### Menu

- **File > Mount Disk Image** (Cmd+O): Open file dialog for Drive 1
- **File > Mount Disk Image to Drive 2** (Cmd+Shift+O): Open for Drive 2

## Disk Images

NorthMac reads .NSI (NorthStar Image) files. These are raw sector dumps:

- **350KB** (Q-density): Double-sided, double-density, 35 tracks
- **175KB** (D-density): Single-sided, double-density, 35 tracks
- **87.5KB** (S-density): Single-sided, single-density, 35 tracks

### Included Disk Images

Located in `Disk Images/`:

**CP/M Operating Systems** (`nscos/`):
- `N2212_64.NSI` - NorthStar CP/M 2.2 release 1.20, 64K
- `N22A_56.NSI` - NorthStar CP/M 2.2 release A, 56K
- `C145_54.NSI` - LifeBoat CP/M 1.45, 54K
- `C223_52.NSI` / `C223_56.NSI` - LifeBoat CP/M 2.23
- `XITANCPM.NSI` - Xitan CP/M 2.26, 48K

**Diagnostics**:
- `DEMODIAG_220.NSI` - NorthStar Advantage Integrity Test

**Other Software** (`nsother/`):
- `FORTH.NSI` / `FORTHSRC.NSI` - Forth language
- `DMF.NSI` - DMF word processor
- Various source disks

## Boot Process

1. On startup, the emulator loads the 2KB boot PROM
2. The PROM displays "LOAD SYSTEM" and waits for input
3. Press **RETURN** to boot from Drive 1
4. Press **D**, then a drive number (**1** or **2**), then **RETURN** to select a specific drive
5. The boot loader reads sectors from the disk and transfers control to the loaded program

## Troubleshooting

**Display is blank**: Click the display area to ensure keyboard focus, then press RETURN.

**Disk won't boot**: Not all disk images are bootable. CP/M system disks (N2212_64, C145_54) and DEMODIAG are known to work. Data-only disks require a booted CP/M system.

**Slow startup**: The boot ROM has delay loops that take several seconds. Enable Turbo mode for faster booting.

**"Parity Circuit Failed"**: The DEMODIAG integrity test reports this because our parity emulation is simplified. This does not affect normal operation.
