// run_loader.c — verify the GREENFIELD stage-1 loader against a faithful port
// of NorthMac's floppy controller (FloppyDiskController.swift + the IOSystem
// FDC/status/ioctl handling + the run-loop's 34-instruction FDC pacing).
//
// It loads a real .nsi disk image, runs stage1 from 0xC100 exactly as the PROM
// would, advances the FDC state machine every 34 instructions, and stops when
// the loader jumps into stage 2 (PC enters 0x8000-0xBFFF). It then compares the
// bytes the loader deposited at logical 0x8000 against the disk's track-1 data
// (where stage 2 lives), reporting how many match.
//
//   cc -O2 -I../../NorthMac run_loader.c -o run_loader
//   ./run_loader stage1.bin disk.nsi [expected_stage2.bin]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "z80.h"
#include "z80.c"

static uint8_t* RAM;
static uint8_t* DISK;       // .nsi image
static long DISK_LEN;

// ---- floppy drive state (port of FloppyDiskController.Drive, drive 0) ------
static int trackNum=0, sectorNum=9, side=0;
static bool motorOn=false, track0=true;
static int stepDirection=0; static bool stepPulse=false, stepPulsePrev=false;
static int fdcState=0, fdcStateCounter=0, fdcStateSectorNum=0x0F;
static bool sectorMark=true, serialData=false, diskReadFlag=false;
static bool acquireMode=true, acquireModePrev=true;
static uint8_t dataBuffer[0x202]; static int bytePtr=0;
static int ioControlReg=0;
static const int MAXTRACKS=35;

static void incrementSectorNum(void){
    sectorNum=(sectorNum+1)%10;
    fdcStateSectorNum = (sectorNum==9)?0x0F:sectorNum;
}
static void floppyStep(void){
    if(stepDirection==0){ if(trackNum>0){ trackNum--; if(trackNum==0) track0=true; } }
    else { trackNum++; if(trackNum>MAXTRACKS) trackNum=MAXTRACKS; track0=false; }
}
static void startSectorRead(void){ incrementSectorNum(); fdcState=100; fdcStateCounter=0; }
static void storeSectorBuffer(void){
    int store = (side!=0) ? (((MAXTRACKS*2)-1)-trackNum)*10+sectorNum : trackNum*10+sectorNum;
    long off = (long)store*512;
    dataBuffer[0]=0xFB;
    for(int i=0;i<512;i++) dataBuffer[i+1] = (off+i<DISK_LEN)?DISK[off+i]:0;
    int crc=0;
    for(int i=1;i<=512;i++){ int k=dataBuffer[i]^crc; k+=k; if(k&0x100)k++; crc=k&0xFF; }
    dataBuffer[513]=(uint8_t)crc;
    bytePtr=0;
}
static void loadDriveControl(uint8_t data){
    // bit0->drive0, bit1->drive1 (we only model drive 0)
    if(data&0x01) fdcState=0;
    stepDirection=(data&0x20)?1:0;
    if(data&0x10){ stepPulse=true; }
    else { stepPulse=false; if(stepPulsePrev) floppyStep(); }
    stepPulsePrev=stepPulse;
    side=(data&0x40)/0x40;
}
// FDC state machine — called every 34 instructions (FloppyDiskController.floppyState)
static void floppy_state(void){
    switch(fdcState){
    case 0:  fdcState=15; sectorMark=true; break;
    case 15: motorOn=true; sectorMark=true; fdcState=18; fdcStateCounter=60; break;
    case 18: if(--fdcStateCounter==0) fdcState=20; break;
    case 20: incrementSectorNum(); sectorMark=true; fdcState=30; fdcStateCounter=5; break;
    case 30: if(--fdcStateCounter==0) fdcState=35; break;
    case 35: sectorMark=false; fdcState=40; fdcStateCounter=40; break;
    case 40: if(--fdcStateCounter==0) fdcState=15; break;
    case 100: serialData=true; fdcStateCounter=0; break;
    case 200: case 210: case 220: break;
    default: fdcState=15; break;
    }
}

static void port_out_cb(z80* z, uint8_t port, uint8_t val){
    uint8_t hi=port>>4, lo=port&0x0F;
    if(hi==0x0A){                                  // memory map registers
        int reg=lo&3;
        if((val&0x80)==0){ int p=val&7; if(val==0)p=reg; z->mapping_regs[reg]=p*0x4000; }
        else if((val&0x84)==0x84) z->mapping_regs[reg]=0x0E*0x4000;
        else if((val&0x06)==0) z->mapping_regs[reg]=(8+(val&1))*0x4000;
    } else if(hi==0x08){                            // FDC out 0x80-0x83
        switch(lo&3){
        case 1: loadDriveControl(val); break;
        case 2: diskReadFlag=true; motorOn=true; break;
        case 3: break; // write flag (unused by loader)
        default: break;
        }
    } else if(port==0xF8){                          // ioctl
        int cmd=val&7; ioControlReg=cmd;
        if(cmd==5) motorOn=true;
        acquireMode=(val&0x08)!=0;
        if(acquireMode && !acquireModePrev) startSectorRead();
        acquireModePrev=acquireMode;
    }
}
static uint8_t port_in_cb(z80* z, uint8_t port){
    (void)z; uint8_t hi=port>>4, lo=port&0x0F;
    if(hi==0x08){                                   // FDC in
        switch(lo&3){
        case 0: { uint8_t d=(bytePtr<0x202)?dataBuffer[bytePtr]:0xFF;
                  bytePtr++; if(bytePtr>513){ diskReadFlag=false; serialData=false; fdcState=35; }
                  return d; }
        case 1: { storeSectorBuffer(); return 0xFB; }
        case 2: diskReadFlag=false; return 0xFF;
        default: return 0xFF;
        }
    }
    if(port==0xE0){                                 // status reg 1
        uint8_t s=0x02;                             // bit1 = !ioInterrupt
        if(track0) s|=0x20;
        if(sectorMark) s|=0x40;
        if(serialData) s|=0x80;
        return s;
    }
    if(port==0xD0){                                 // status reg 2
        uint8_t s=0;
        if(ioControlReg==0||ioControlReg==5){ s = motorOn ? (fdcStateSectorNum&0x0F) : 0x0E; }
        return s;
    }
    return 0xFF;
}

int main(int argc,char**argv){
    if(argc<3){ fprintf(stderr,"usage: run_loader stage1.bin disk.nsi [stage2.bin]\n"); return 2; }
    RAM=calloc(256*1024,1);
    FILE* f=fopen(argv[2],"rb"); if(!f){perror("disk");return 1;}
    fseek(f,0,SEEK_END); DISK_LEN=ftell(f); fseek(f,0,SEEK_SET);
    DISK=malloc(DISK_LEN); fread(DISK,1,DISK_LEN,f); fclose(f);
    // stage1 lands where the PROM puts the boot payload: bank3 logical 0xC100
    f=fopen(argv[1],"rb"); if(!f){perror("stage1");return 1;}
    size_t n=fread(RAM+0x0C100,1,4096,f); fclose(f);
    fprintf(stderr,"stage1 %zu bytes; disk %ld bytes\n",n,DISK_LEN);

    z80 cpu; z80_init(&cpu);
    cpu.ram=RAM; cpu.use_direct_memory=true;
    cpu.port_in=port_in_cb; cpu.port_out=port_out_cb;
    cpu.mapping_regs[0]=0x00000; cpu.mapping_regs[1]=0x04000;
    cpu.mapping_regs[2]=0x38000; cpu.mapping_regs[3]=0x0C000;
    cpu.pc=0xC10A;

    int pulse=0; unsigned long budget=2000000000UL;
    while(cpu.cyc<budget){
        z80_step(&cpu);
        if(++pulse>=34){ pulse=0; floppy_state(); }
        if(cpu.pc>=0x8000 && cpu.pc<0xC000){        // jumped into stage 2
            fprintf(stderr,"reached stage 2 at PC=%04X after %lu cycles\n",cpu.pc,cpu.cyc);
            break;
        }
    }
    if(cpu.cyc>=budget) fprintf(stderr,"BUDGET EXHAUSTED at PC=%04X (loader hung?)\n",cpu.pc);

    // stage2 lives on disk at track 1 = file offset 0x1400 (storeSectNum 10)
    long t1 = 10*512;
    int cmp=(argc>=4)?-1:512*10;
    long expect_len = 512*10;
    uint8_t* expect = DISK + t1;
    if(argc>=4){ FILE* e=fopen(argv[3],"rb"); fseek(e,0,SEEK_END); expect_len=ftell(e);
                 fseek(e,0,SEEK_SET); expect=malloc(expect_len); fread(expect,1,expect_len,e); fclose(e); }
    long match=0,total=expect_len<5120?expect_len:5120;
    for(long i=0;i<total;i++) if(RAM[0x04000+i]==expect[i]) match++;
    fprintf(stderr,"stage2 bytes correct at 0x8000: %ld / %ld\n",match,total);
    fprintf(stderr,"first 16 @0x8000: ");
    for(int i=0;i<16;i++) fprintf(stderr,"%02X ",RAM[0x04000+i]);
    fprintf(stderr,"\nexpected      : ");
    for(int i=0;i<16;i++) fprintf(stderr,"%02X ",expect[i]);
    fprintf(stderr,"\n");
    (void)cmp;
    return 0;
}
