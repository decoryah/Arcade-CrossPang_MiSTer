#!/bin/sh
# What the framework's scandoubler (arcade_video) does with this core's raster and CRT Adjust, without the machine (after the owner's
# Monster Maulers core, sim/emu/run_sd.sh):
#   [CRT=0|1] [GATE=0|1] sim/sd/run_sd.sh [frames] [fx 0..4] [forced_scandoubler 0|1]
# CRT=1: the OSD's CRT Adjust On.  GATE=1 (the default) is the core's wiring (Crospang.sv: CRT Adjust off while the scandoubler is in
# use), GATE=0 the wiring before it.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
S=../../sys
OBJ="${OBJ:-$HOME/build_crospang_sd_c${CRT:-0}_g${GATE:-1}}"
mkdir -p $OBJ
# video_mixer.sv: take the plain (non-HALF_DEPTH) branch of its gamma generate block, which Verilator cannot elaborate as written
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
verilator --cc --exe --build -j ${JOBS:-2} -O2 -GCRT=${CRT:-0} -GGATE=${GATE:-1} -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT \
    -Wno-PINMISSING -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED \
    -Wno-CMPCONST -Wno-PROCASSWIRE \
    +1364-2005ext+v -I. -I../.. --top-module tb_sd_top --prefix Vtb_sd_top -Mdir $OBJ \
    ../../rtl/cp_ram.sv ../../rtl/cp_video.sv ../../rtl/cp_crtadj.sv ../../modules/crt_adjust/crt_adjust.sv \
    $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv \
    sync_fix.sv tb_sd_top.sv tb_sd.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -20; tail -5 $OBJ.log; exit 1; }
"$OBJ"/Vtb_sd_top "${1:-6}" "${2:-0}" "${3:-0}"
