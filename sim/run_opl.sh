#!/bin/bash
# YM3812 bench (sim/tb_opl.sv, sim/tb_opl.cpp), in WSL:
#   sim/run_opl.sh <ymlog.txt> <seconds> <out.wav>
# Build directory: $HOME/build_crospang_opl (NOBUILD=1 reuses it).
set -e
cd "$(dirname "$0")"
LOG="$1"; SECS="${2:-12}"; OUT="$3"
case "$LOG" in /*) ;; *) LOG="$PWD/$LOG" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_crospang_opl}"; mkdir -p "$B"
M=../modules
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-INITIALDLY -Wno-LATCH -Wno-MULTIDRIVEN \
    -Wno-BLKANDNBLK -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-PINMISSING -Wno-COMBDLY -Wno-IMPLICIT \
    --top-module tb_opl -Mdir "$B/obj" \
    ../rtl/cp_cen.sv $M/jtopl/jtopl2.v $(ls $M/jtopl/jtopl*.v | grep -v 'jtopl2\.v') \
    tb_opl.sv tb_opl.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vtb_opl" "$LOG" "$SECS" "$OUT"
