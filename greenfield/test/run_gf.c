// run_gf.c — headless harness that boots a GREENFIELD payload on the *real*
// NorthStar z80 core (NorthMac/z80.c) and dumps the resulting framebuffer.
//
// We skip the PROM disk-load (already proven correct by byte-identical layout
// to shipping Advantage disks) and start exactly where the PROM's JP (HL)
// lands: PC=0xC10A, with the address space mapped the way the PROM leaves it.
// Bank mapping + the write-guard come straight from z80.c, so memory behaves
// identically to the GUI emulator.
//
// It also models just enough of the keyboard (status regs 0xD0/0xE0, the IOCTL
// 0xF8 command + ack-toggle handshake) to (a) keep GREENFIELD's keyboard poll
// from hanging and (b) inject scripted keypresses for verifying interactivity.
//
//   cc -O2 -I../../NorthMac run_gf.c -o run_gf
//   ./run_gf greenfield.bin fb.raw [maxcycles] ["cyc:hex,cyc:hex,..."]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "z80.h"
#include "z80.c"

static uint8_t* RAM;

// ---- keyboard model --------------------------------------------------------
static int kbd_char = 0;   // current key value (nibbles read from here)
static int kbd_flag = 0;   // 1 = a key is pending (clears when high nibble read)
static int kbd_cmd  = 0;   // IOCTL command field (bits 0-2 of last 0xF8 write)
static int kbd_ack  = 0;   // toggles on every 0xF8 write (handshake)
static int spk_last = 0;   // last speaker bit (IOCTL bit6)
static long spk_toggles = 0;  // count of speaker transitions (= sound activity)

// scripted injection: keys[] released when cyc passes when[]
#define MAXKEYS 16
static unsigned long key_when[MAXKEYS];
static int key_val[MAXKEYS];
static int key_n = 0, key_i = 0;

static void port_out_cb(z80* z, uint8_t port, uint8_t val) {
    if ((port >> 4) == 0x0A) {                 // 0xA0-0xA3: memory map registers
        int reg = port & 3;
        if ((val & 0x80) == 0) {
            int page = val & 0x07;
            if (val == 0) page = reg;
            z->mapping_regs[reg] = page * 0x4000;
        } else if ((val & 0x84) == 0x84) {
            z->mapping_regs[reg] = 0x0E * 0x4000;
        } else if ((val & 0x06) == 0) {
            z->mapping_regs[reg] = (8 + (val & 1)) * 0x4000;
        }
    } else if (port == 0xF8) {                 // IOCTL: command select + ack flip
        int spk = (val & 0x40) ? 1 : 0;        // bit6 = speaker
        if (spk != spk_last) { spk_toggles++; spk_last = spk; }
        kbd_cmd = val & 0x07;
        kbd_ack ^= 1;
    }
    // 0x90 (scanline scroll) and 0xB0 (clear flag) need no model for a dump.
}

static uint8_t port_in_cb(z80* z, uint8_t port) {
    (void)z;
    if (port == 0xE0) {                        // status reg 1
        return kbd_flag ? 0x01 : 0x00;         // bit0 = key available
    }
    if (port == 0xD0) {                        // status reg 2
        uint8_t s = 0;
        if (kbd_flag) s |= 0x40;               // bit6 = data flag
        if (kbd_ack)  s |= 0x80;               // bit7 = command ack
        if (kbd_cmd == 1) {                    // low nibble
            s |= (kbd_char & 0x0F);
        } else if (kbd_cmd == 2) {             // high nibble; reading clears flag
            s |= ((kbd_char >> 4) & 0x0F);
            kbd_flag = 0;
        }
        return s;
    }
    return 0xFF;
}

static void parse_keys(const char* spec) {
    char buf[256];
    strncpy(buf, spec, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    char* tok = strtok(buf, ",");
    while (tok && key_n < MAXKEYS) {
        unsigned long w; int c;
        if (sscanf(tok, "%lu:%x", &w, &c) == 2) {
            key_when[key_n] = w; key_val[key_n] = c; key_n++;
        }
        tok = strtok(NULL, ",");
    }
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: run_gf <payload.bin> <out.raw> [maxcycles] [keys]\n");
        return 2;
    }
    unsigned long BUDGET = (argc >= 4) ? strtoul(argv[3], NULL, 0) : 200000000UL;
    if (argc >= 5 && argv[4][0]) parse_keys(argv[4]);
    int pace_force = (argc >= 6) ? atoi(argv[5]) : -1;   // pin paceLvl for fast renders
    int mode_force = (argc >= 7) ? atoi(argv[6]) : -1;   // pin gallery mode

    const int PACE_ADDR = 0x0CE2C;   // logical 0xCE2C in bank 3
    const int MODE_ADDR = 0x0CE0D;   // logical 0xCE0D in bank 3

    RAM = calloc(256 * 1024, 1);
    if (!RAM) return 1;

    // Read the binary, then auto-detect which stage it is by its first byte:
    //   0xC1 = stage1 (PROM boot header) -> load at bank3:0x100, enter 0xC10A
    //   else = stage2 (the art at org 0x8000) -> load into bank1, enter 0x8000
    uint8_t hdr[1] = {0};
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror("open payload"); return 1; }
    if (fread(hdr, 1, 1, f) != 1) { return 1; }
    rewind(f);

    z80 cpu;
    z80_init(&cpu);
    cpu.ram = RAM;
    cpu.use_direct_memory = true;
    cpu.port_in = port_in_cb;
    cpu.port_out = port_out_cb;

    if (hdr[0] == 0xC1) {                          // ---- stage 1 ----
        size_t n = fread(RAM + 0x0C100, 1, 4096, f);
        fprintf(stderr, "stage1: loaded %zu bytes at phys 0x0C100\n", n);
        cpu.mapping_regs[0] = 0x00000;
        cpu.mapping_regs[1] = 0x04000;
        cpu.mapping_regs[2] = 0x38000;
        cpu.mapping_regs[3] = 0x0C000;
        cpu.pc = 0xC10A;
    } else {                                       // ---- stage 2 ----
        size_t n = fread(RAM + 0x04000, 1, 16384, f);  // bank 1 = logical 0x8000
        fprintf(stderr, "stage2: loaded %zu bytes at phys 0x04000 (logical 0x8000)\n", n);
        cpu.mapping_regs[0] = 0x00000;
        cpu.mapping_regs[1] = 0x04000;
        cpu.mapping_regs[2] = 0x04000;             // page2 -> bank1 = stage2 code
        cpu.mapping_regs[3] = 0x0C000;             // page3 -> bank3 = data/stack
        cpu.pc = 0x8000;
    }
    fclose(f);

    int stuck = 0;
    while (cpu.cyc < BUDGET) {
        // release any scripted key whose time has come
        if (key_i < key_n && cpu.cyc >= key_when[key_i]) {
            kbd_char = key_val[key_i];
            kbd_flag = 1;
            key_i++;
        }
        if (pace_force >= 0) RAM[PACE_ADDR] = (uint8_t)pace_force;  // pin pace
        if (mode_force >= 0) RAM[MODE_ADDR] = (uint8_t)mode_force;  // pin mode
        uint16_t p = cpu.pc;
        z80_step(&cpu);
        if (cpu.pc == p) { if (++stuck > 2000) break; } else stuck = 0;
    }
    fprintf(stderr, "halted at PC=%04X after %lu cycles (stuck=%d)\n",
            cpu.pc, cpu.cyc, stuck);
    fprintf(stderr, "mode byte (0xCE0D) = %d  paceLvl (0xCE2C) = %d\n",
            RAM[0x0C000 + 0x0E0D], RAM[PACE_ADDR]);

    FILE* o = fopen(argv[2], "wb");
    if (!o) { perror("open out"); return 1; }
    fwrite(RAM + 0x20000, 1, 80 * 256, o);
    fclose(o);

    long nz = 0;
    for (int i = 0; i < 80 * 256; i++) if (RAM[0x20000 + i]) nz++;
    fprintf(stderr, "video non-zero bytes: %ld / %d\n", nz, 80 * 256);
    fprintf(stderr, "speaker toggles: %ld\n", spk_toggles);
    return 0;
}
