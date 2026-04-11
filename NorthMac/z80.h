#ifndef Z80_Z80_H_
#define Z80_Z80_H_

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct z80 z80;
struct z80 {
  uint8_t (*read_byte)(void*, uint16_t);
  void (*write_byte)(void*, uint16_t, uint8_t);
  uint8_t (*port_in)(z80*, uint8_t);
  void (*port_out)(z80*, uint8_t, uint8_t);
  void* userdata;

  // Direct memory access (bypasses read_byte/write_byte callbacks when set)
  uint8_t* ram;             // pointer to 256KB physical RAM
  int mapping_regs[4];      // maps logical 16KB pages to physical byte offsets
  bool use_direct_memory;   // enable direct memory access mode
  bool video_dirty;         // set when video RAM (0x20000-0x27FFF) is written
  bool mapping_regs_dirty;  // set by port_out when mapping registers change

  unsigned long cyc; // cycle count (t-states)

  uint16_t pc, sp, ix, iy; // special purpose registers
  uint16_t mem_ptr; // "wz" register
  uint8_t a, b, c, d, e, h, l; // main registers
  uint8_t a_, b_, c_, d_, e_, h_, l_, f_; // alternate registers
  uint8_t i, r; // interrupt vector, memory refresh

  // flags: sign, zero, yf, half-carry, xf, parity/overflow, negative, carry
  bool sf : 1, zf : 1, yf : 1, hf : 1, xf : 1, pf : 1, nf : 1, cf : 1;

  uint8_t iff_delay;
  uint8_t interrupt_mode;
  uint8_t int_data;
  bool iff1 : 1, iff2 : 1;
  bool halted : 1;
  bool int_pending : 1, nmi_pending : 1;
};

void z80_init(z80* const z);
void z80_step(z80* const z);
unsigned long z80_run(z80* const z, unsigned long max_cycles);
void z80_debug_output(z80* const z);
void z80_gen_nmi(z80* const z);
void z80_gen_int(z80* const z, uint8_t data);

// Frame runner: executes one frame's worth of Z80 instructions in a tight C loop.
// Calls fdc_callback every fdc_pulse instructions. Returns 0=frame done, 1=halted, 2=stopped.
typedef struct {
  z80* cpu;
  unsigned long cycles_per_frame;
  unsigned long frame_cycles;
  int fdc_pulse;            // advance FDC every N instructions (34)
  bool should_run;
  // MED3C trap: when trap_active && PC matches && ram[0xF33C]==0xC9, call trap callback
  bool trap_active;
  uint16_t trap_pc1;        // 0xF33C
  uint16_t trap_pc2;        // 0xF33F
  // Callbacks into Swift
  void (*fdc_callback)(void* userdata, z80* cpu);  // advance FDC + check interrupts
  void (*trap_callback)(void* userdata);            // handle MED3C trap
  void (*sync_mapping)(void* userdata);             // sync mapping registers
  void* userdata;
} frame_context;

int emulator_run_frame(frame_context* ctx);

#endif // Z80_Z80_H_
