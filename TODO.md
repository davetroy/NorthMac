# NorthMac TODO

## Speed Optimizations

- [ ] Use `UnsafeMutableBufferPointer` for RAM array access in MemorySystem to eliminate bounds checking overhead on every read/write
- [ ] Investigate `writeByte` branch optimization — currently two range comparisons per write; could use a page-type lookup table
- [ ] Profile C↔Swift callback overhead in Z80 CPU `read_byte`/`write_byte` (`Unmanaged.fromOpaque` on every memory access)
- [ ] Consider batching display dirty flag checks instead of per-write in video RAM range

## Hardware Emulation

- [ ] Parallel port (PIO) emulation — directly print to macOS printer or PDF
- [ ] Serial port (SIO) emulation — connect to macOS pseudo-TTY or TCP socket
- [ ] 8/16 module emulation (8086 co-processor) for MS-DOS support
- [ ] Additional expansion board emulation (other slot cards)

## Features

- [ ] Disk write support (currently read-only)
- [ ] Drag-and-drop disk image mounting
- [ ] File transfer between host and emulated CP/M filesystem
