#!/bin/bash
# Whole-machine / frozen-state bench (sim/tb_top.sv, sim/tb_main.cpp), in WSL:
#   sim/run.sh <image.rom> <frames> <out-prefix> [bench arguments: +state=<prefix> +load=rtl +every=N +first=N +foff=K +inputs=F +dsw=HEX +trace +wav ...]
# The image is tools/crospang_image.py's.  Writes <out-prefix>.fNNNNN.ppm (+ .wav, .trace).  Build directory: $HOME/build_crospang
# (NOBUILD=1 reuses it).
set -e
cd "$(dirname "$0")"
ROM="$1"; FRAMES="${2:-3}"; OUT="$3"; shift 3 || true
[ -f "$ROM" ] || { echo "usage: $0 <image.rom> <frames> <out-prefix> [args]" >&2; exit 2; }
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_crospang}"; mkdir -p "$B"
M=../modules
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" --public-flat-rw \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-UNUSEDPARAM -Wno-IMPLICIT -Wno-CASEX -Wno-COMBDLY -Wno-SELRANGE -Wno-ASCRANGE \
    $VFLAGS --top-module tb_top -Mdir "$B/obj" \
    ../rtl/cp_ram.sv ../rtl/cp_cen.sv ../rtl/cp_cache.sv ../rtl/cp_main.sv ../rtl/cp_video.sv ../rtl/cp_render.sv \
    ../rtl/cp_sound.sv ../rtl/cp_core.sv ../rtl/cp_mem.sv ../rtl/cp_fastload.sv ../rtl/sdram_ctrl.sv \
    $M/cpu-fx68k/fx68kAlu.sv $M/cpu-fx68k/uaddrPla.sv $M/cpu-fx68k/fx68k.sv \
    $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_mcode.v $M/cpu-tv80/tv80_reg.v $M/cpu-tv80/tv80s_cen.v \
    $M/jtopl/jtopl2.v $(ls $M/jtopl/jtopl*.v | grep -v 'jtopl2\.v') \
    $M/jt6295/hdl/jt6295.v $M/jt6295/hdl/jt6295_adpcm.v $M/jt6295/hdl/jt6295_timing.v \
    $M/jt6295/hdl/jt6295_acc.v $M/jt6295/hdl/jt6295_ctrl.v $M/jt6295/hdl/jt6295_rom.v \
    $M/jt6295/hdl/jt6295_serial.v $M/jt6295/hdl/jt6295_sh_rst.v \
    sdram_model.sv tb_top.sv tb_main.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp ../microrom.mem ../nanorom.mem "$B/"
cd "$B"
./obj/Vtb_top "$ROM" "$FRAMES" "$OUT" "$@"
