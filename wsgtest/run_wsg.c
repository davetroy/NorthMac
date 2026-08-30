// run_wsg.c — headless NS-WSG harness: runs a bare-metal Advantage payload
// against a model of the NS-WSG v1 spec (NorthMac/Documentation/NSWSG.md)
// and renders the card's output to a 96 kHz mono WAV file.
//
// The WSG model here is written independently of the Swift one so the two
// implementations cross-check each other (both must match the spec).
//
//   cc -O2 -I../../NorthMac/NorthMac run_wsg.c -o run_wsg   (NorthMac z80 fork)
//   ./run_wsg payload.bin out.wav [maxcycles]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include "z80.h"
#include "z80.c"

static uint8_t* RAM;

// ---- NS-WSG model (spec: NSWSG.md) -----------------------------------------
#define WSG_SLOT_IDX 3            // ID index 3 -> slot 3 -> base 0x30
#define WSG_BASE 0x30
static uint8_t waveRAM[256];
static int wtIndex = 0, wsgEnable = 0;
static uint32_t wfreq[3];
static int wvol[3], wsel[3];
static uint32_t wacc[3];

static void wsg_out(uint8_t reg, uint8_t val){
    switch(reg){
    case 0x0: wtIndex = val; break;
    case 0x1: waveRAM[wtIndex] = val & 0x0F; wtIndex = (wtIndex+1)&0xFF; break;
    case 0x2: wsgEnable = val & 1; if(!wsgEnable) wacc[0]=wacc[1]=wacc[2]=0; break;
    default:
        if(reg >= 4){
            int v = (reg-4)/4;
            switch((reg-4)&3){
            case 0: wfreq[v] = (wfreq[v] & 0xFFF00) | val; break;
            case 1: wfreq[v] = (wfreq[v] & 0xF00FF) | ((uint32_t)val<<8); break;
            case 2: wfreq[v] = (wfreq[v] & 0x0FFFF) | ((uint32_t)(val&0x0F)<<16); break;
            default: wvol[v] = val & 0x0F; wsel[v] = (val>>4)&7; break;
            }
        }
    }
}
static float wsg_tick(void){                 // one 96 kHz tick -> one sample
    if(!wsgEnable) return 0.0f;
    float mix = 0.0f;
    for(int v=0; v<3; v++){
        if(!wvol[v] || !wfreq[v]) continue;
        wacc[v] = (wacc[v] + wfreq[v]) & 0xFFFFF;
        int nib = waveRAM[(wsel[v]<<5) | (wacc[v]>>15)];
        mix += ((float)nib - 7.5f)/7.5f * ((float)wvol[v]/15.0f);
    }
    return mix * 0.28f;
}

// ---- machine model ---------------------------------------------------------
static void port_out_cb(z80* z, uint8_t port, uint8_t val){
    uint8_t hi = port >> 4, lo = port & 0x0F;
    if(hi == 0x0A){                          // memory map registers
        int reg = lo & 3;
        if((val & 0x80) == 0){ int p = val & 7; if(val == 0) p = reg; z->mapping_regs[reg] = p*0x4000; }
        else if((val & 0x84) == 0x84) z->mapping_regs[reg] = 0x0E*0x4000;
        else if((val & 0x06) == 0) z->mapping_regs[reg] = (8+(val&1))*0x4000;
    } else if(hi == (WSG_BASE>>4)){
        wsg_out(lo, val);
    }
}
static uint8_t port_in_cb(z80* z, uint8_t port){
    (void)z;
    uint8_t hi = port >> 4, lo = port & 0x0F;
    if(hi == (WSG_BASE>>4)) return lo == 0x3 ? 0x57 : 0xFF;
    if(hi == 0x07){                          // board IDs
        return ((lo & 0x07) == WSG_SLOT_IDX) ? 0xA5 : 0xFF;
    }
    return 0xFF;
}

static void wav_write(const char* path, const int16_t* pcm, long n, int rate){
    FILE* f = fopen(path, "wb");
    if(!f){ perror("wav"); exit(1); }
    long data = n*2;
    uint32_t u32; uint16_t u16;
    fwrite("RIFF",1,4,f); u32=36+data; fwrite(&u32,4,1,f); fwrite("WAVE",1,4,f);
    fwrite("fmt ",1,4,f); u32=16; fwrite(&u32,4,1,f);
    u16=1; fwrite(&u16,2,1,f); u16=1; fwrite(&u16,2,1,f);          // PCM, mono
    u32=rate; fwrite(&u32,4,1,f); u32=rate*2; fwrite(&u32,4,1,f);
    u16=2; fwrite(&u16,2,1,f); u16=16; fwrite(&u16,2,1,f);
    fwrite("data",1,4,f); u32=data; fwrite(&u32,4,1,f);
    fwrite(pcm,2,n,f); fclose(f);
}

int main(int argc, char** argv){
    if(argc < 3){ fprintf(stderr,"usage: run_wsg payload.bin out.wav [maxcycles]\n"); return 2; }
    unsigned long budget = (argc >= 4) ? strtoul(argv[3],0,10) : 40000000UL;   // 10 s

    RAM = calloc(256*1024, 1);
    FILE* f = fopen(argv[1], "rb"); if(!f){ perror("payload"); return 1; }
    size_t n = fread(RAM + 0x04000, 1, 0x4000, f); fclose(f);
    fprintf(stderr, "payload %zu bytes at 0x8000\n", n);

    z80 cpu; z80_init(&cpu);
    cpu.ram = RAM; cpu.use_direct_memory = true;
    cpu.port_in = port_in_cb; cpu.port_out = port_out_cb;
    cpu.mapping_regs[0] = 0x00000; cpu.mapping_regs[1] = 0x04000;
    cpu.mapping_regs[2] = 0x04000; cpu.mapping_regs[3] = 0x0C000;
    cpu.pc = 0x8000;

    long maxSamples = (long)(budget/41.6667) + 96000;
    int16_t* pcm = malloc(maxSamples*2);
    long ns = 0;
    double nextTick = 0.0;
    const double cyclesPerTick = 4000000.0/96000.0;

    int warned = 0;
    while(cpu.cyc < budget){
        z80_step(&cpu);
        if(!warned && cpu.sp && cpu.sp < 0xFD00){
            fprintf(stderr, "SP LEAK: sp=%04X at pc=%04X cyc=%llu\n",
                    cpu.sp, cpu.pc, (unsigned long long)cpu.cyc);
            warned = 1;
        }
        while((double)cpu.cyc >= nextTick && ns < maxSamples){
            float s = wsg_tick();
            if(s > 1.0f) s = 1.0f; if(s < -1.0f) s = -1.0f;
            pcm[ns++] = (int16_t)(s*32000.0f);
            nextTick += cyclesPerTick;
        }
    }
    wav_write(argv[2], pcm, ns, 96000);

    double rms = 0; for(long i=0;i<ns;i++) rms += (double)pcm[i]*pcm[i];
    rms = ns ? sqrt(rms/ns) : 0;
    fprintf(stderr, "wrote %s: %ld samples (%.1f s), rms=%.0f, enable=%d vols=%d/%d/%d pc=%04X sp=%04X\n",
            argv[2], ns, ns/96000.0, rms, wsgEnable, wvol[0], wvol[1], wvol[2], cpu.pc, cpu.sp);
    return 0;
}
