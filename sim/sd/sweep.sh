#!/bin/sh
# run_sd.sh over the cases that matter: CRT Adjust off / on, without and with the core's gate, 15 kHz / forced scandoubler / HQ2x /
# CRT 25 %.  Prints the last lines of each run ("done ... frames counted" or "STALLED").
cd "$(dirname "$0")"
for c in "1 0 0 1" "1 1 0 1" "0 1 0 1" "1 1 1 0" "1 1 2 0" "1 1 0 0" "0 1 0 0"; do
    set -- $c
    echo "=== CRT Adjust $1, gate $2, Scandoubler Fx $3, forced_scandoubler $4"
    CRT=$1 GATE=$2 nice -n 10 ./run_sd.sh ${FRAMES:-4} $3 $4 | tail -${LINES:-3}
done
