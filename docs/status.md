# Status and measurements (2026-10-19)

Every number below is from MAME 0.289 and Verilator / Quartus runs on the owner's machine; the scripts are in `../tools/`
(`tools/paths.py` says where they look for MAME, the romsets and the scratch folder `work/`), the benches in `../sim/`.

## On a MiSTer

The owner's tests of the first build with the regenerated MRAs (2026-10-19): **all six sets load and run; sound, video and controls
good; the DIP switches and the CRT adjust page work.** The first try stopped at the MRAs' md5 (see the ROM path table). Findings, and
what the second build of the day changed:

* **The Service button did nothing: removed.** It held SW2:7 on, which is Cross Pang's service switch but not the others' (Heuk Sun and
  Pitapat: SW1:8, Bestri: SW1:1; in Pitapat SW2:7 is an unknown switch the driver suspects of affecting difficulty). And no game would
  have seen it: `tools/service.py` (MAME, `tools/lua/service.lua`) shows every game reads the DSW port exactly once, while it boots
  (Pitapat in frame 8, Heuk Sun and Bestri 15, Cross Pang 21), and the service switch turned on in the attract mode changes no pixel up
  to frame 1200. The owner found the same: the OSD's Service Mode switch works after a reset.
* **Video RAM: Live made no visible difference.** As expected: Live draws from the video RAMs while the game rewrites them, so the
  picture is one frame newer (the bench's `+foff` is -1 instead of -2) and only an object that moves in the top lines can tear (the
  games finish their sprite lists 1.3-2.6 ms after the interrupt, within the first ~20 lines). The option is now "Live (less lag)".
* **Button 3, and what every button does.** `tools/probe.py` (MAME, `tools/lua/probe.lua`) presses any input bit at the 68000's port
  read -- also the bits MAME's INPUT_PORTS leave unknown -- and compares the pictures with a run without the press:

| set | button 1 | button 2 | button 3 (P1_P2 bit 6 / 14) | from |
|---|---|---|---|---|
| crospang | picks up / drops the ball under the ring | Power: one of the "P" icons goes, balls burst | new balls come up | the demo's helper ("Button B is for Power"), its input display (buttons A, B, **C**), presses in play at frame 1100 |
| heuksun | places a stone | opens the menu: retry, take back a move, give up, hint | no effect | presses in a problem (frame 1100) and in the menu |
| bestri | Die Break: launches the ball; Heuk Sun Baek Sa and Penta (omok): place a stone | Die Break: jump; Heuk Sun Baek Sa: the menu; Penta: no effect found | no effect in any of the three | presses in each game (selected with the joystick on the title screen before start) |
| pitapat | picks up / exchanges / drops a marvel | brings up more marvels | turns all boxes into marvels (DIP "Boxes to Marvels": how often) | the attract mode's How to Play; button 3 held periodically in play: the pictures differ from frame 1250 on (score 1,200 vs 0 at frame 1500) |

  MAME 0.289 has button 3 for Pitapat (IPT_BUTTON3) but not for Cross Pang (IPT_UNKNOWN), so Cross Pang's is beyond MAME. The core
  passes button 3 only where the MRA's configuration byte 5 is 1 (crospang, pitapat, pitapata); the MRAs name the buttons
  (`tools/make_mra.py` BUTTONS). New md5s: crospang 8760b3c2810a2e64a44a4ce1feee8454, pitapat ebfc1902dcf040b6099c5476633cbf92,
  pitapata a2d09ffbf4ced80cbd8c05c17d7ee188 (the other three unchanged).
* **The owner's test of the second build:** button 3 works in Cross Pang; in Pitapat its effect was unclear. It only acts while boxes
  are on the player's field, and only as often as the "×1" card at the top left of the field allows (DIP "Boxes to Marvels": 1 or 2).
  MAME, one press at frame 1218 of the scripted play (`B3=1 B3_AT=1218` with `tools/lua/dump_state.lua`; coin 600, start 700): the
  boxes turn into marvels within 10 frames, everything blows up as one combo (frame 1264), and at frame 1300 the field is empty, the
  score 1,200 (0 without the press) and the card gone.
* **Third build: the buttons in the order Button 1, 2, 3, Start, Coin** when mapping (the owner's request): joystick bits 4-8 in that
  order (`Crospang.sv`); the sets without button 3 name it "-" in the MRA, which MiSTer skips when mapping (Main_MiSTer `input.cpp`),
  and their `default` list leaves it out (`joymapping.cpp` `map_joystick()` takes the next default name for the next mapped button).
  MiSTer keeps a mapping per set name (the MRA's `<setname>` replaces the core name in `<name>_input_*.map`), so every game is mapped
  once more after the order change.
* **Fourth build (the owner's request): Scale, fast load, and CRT Adjust off under the scandoubler.** Scale (Normal, V-Integer,
  HV-Integer, Narrower HV-Integer, HV-Integer+) as in the owner's Monster Maulers / Violent Storm / Gaiapolis cores; the fast load
  (MRA `address=`, `rtl/cp_fastload.sv`) and the scandoubler check below.

## The scandoubler (`sim/sd/run_sd.sh`, `sim/sd/sweep.sh`)

The framework's `sys/scandoubler.v` (Scandoubler Fx, MiSTer.ini's `forced_scandoubler`) takes its line timing from the edges of
`HBlank` and needs them on every line, the vertical blank's included; held high through the vertical blank, the doubled picture gets no
vertical sync and stands still (found on the owner's Monster Maulers core). The core's own `HBlank` (`rtl/cp_video.sv`) is the
horizontal blank alone, but CRT Adjust (`rtl/cp_crtadj.sv`) gives rmonic79's module the combined blank and passes its output on.
The bench feeds the core's raster through CRT Adjust into the framework's `arcade_video` and counts the output frames (4 frames each):

| CRT Adjust | gate (`Crospang.sv`) | Scandoubler Fx | forced_scandoubler | result |
|---|---|---|---|---|
| On | none (the first three builds) | None | 1 | **STALLED**: no VGA_VS in 12 M clocks (the frozen picture) |
| On | CRT Adjust off while the scandoubler is in use | None | 1 | 6 frames; 480 lines, each source line twice, in order |
| Off | - | None | 1 | the same |
| On | gate | HQ2x | 0 | 6 frames, 480 lines in order (HQ2x blends the doubled lines) |
| On | gate | CRT 25 % | 0 | 6 frames, 480 lines, each twice, in order |
| On / Off | gate | None | 0 (15 kHz) | 6 frames, 240 lines in order |

So the earlier builds froze with the scandoubler only while CRT Adjust was On (default Off); the 15 kHz output was never affected.

## Fast load (`sim/run.sh <image> 0 <out> +load=fast`)

`rtl/cp_fastload.sv` against a DDR3 model in `sim/tb_top.sv` (busy at random and during a burst, the beats 20 clocks late with gaps;
the image at byte 0x32000000, beat 0x6400000): crospang and pitapat images, 0 of 2,752,512 SDRAM words, 0 of 65,536 Z80 ROM bytes
and 0 of 8 configuration bytes differ; **19.6 M clocks (0.20 s)** from the end of the empty download to the last word in the SDRAM.
The ordinary path through the same bench (`+load=rtl`, heuksun): 0 differences as before.

## ROM path

| check | result |
|---|---|
| `tools/crospang_rom.py check`: the regions built from the ROM_START lists vs MAME's loaded regions (`tools/lua/dump_regions.lua`) | all 6 sets x 5 regions (maincpu, audiocpu, oki, tiles, sprites) byte-identical |
| `tools/crospang_image.py check`: the loader's graphics remap + the renderer's pixel pick vs MAME's gfx decode (`tlayout`, `tlayout_alt`) | all 166,912 tiles of the six sets, every row and pixel, identical |
| `tools/make_mra.py`: the image `tools/mra_build.py` builds from each `.mra` and the merged romset vs `crospang_image.py` | all six byte-identical; the DSW defaults the script derives from the driver's `INPUT_PORTS` equal MAME's port values (FF7E crospang, FFFE heuksun, FFFB bestri / bestria, FFFF pitapat / pitapata) |
| the `.mra`'s md5 | MiSTer's (Main_MiSTer `support/arcade/mra_loader.cpp`: MD5 of each part's data as read, in .mra order -- **not** the image's md5 once parts are interleaved; MiSTer does not send a ROM whose md5 differs: "md5 mismatch for rom 0", reported on the first hardware try of 2026-10-19 and fixed). `tools/mra_build.py` now checks that md5 |
| bench `+load=rtl`: the image pushed through `rtl/cp_mem.sv` a byte at a time, then every SDRAM word and Z80 ROM byte read back | heuksun and crospang: 0 of 2,752,512 SDRAM words and 0 of 65,536 Z80 ROM bytes differ |

## Reference renderer (`tools/crospang_ref.py`, MAME's `screen_update` + `decospr` written out)

1,358 MAME frames over all six sets (`tools/capture.py`, scripted play): **0 differing pixels**. A wrong sprite X offset (4 instead of
5) gives 22,236 differing pixels over 5 frames, a wrong Y offset 23,627, no sprites 46,174: the comparison discriminates.

Measured along the way:

* **Flash bit** (`w0` bit 12): hidden when MAME's `frame_number()` is odd. The picture of dumped frame N (`tools/lua/dump_state.lua`
  numbering) is drawn with an odd frame number when N is even (20 consecutive frames, 5 flashing entries).
* **Features used** (1,358 frames): sprites 1 / 2 / 4 / 8 tiles tall and flashing in crospang, heuksun and bestri, flip X / Y only in
  heuksun, the **wide** flag never; tile bank changes in bestri and pitapat; scrolling in heuksun (111 distinct states), bestri,
  pitapat (Cross Pang writes its scroll registers once and never again).

## RTL, frozen states (`tools/corpus_rtl.py`)

The RTL's picture of each MAME state (tile, sprite and palette RAMs and the registers loaded, both CPUs held in reset) against MAME's
pixels, through the real loader layout and SDRAM controller and a behavioural SDRAM chip.  First run (the bench before the video RAM
snapshot and the row reuse), every state of the short captures:

| set | states | pixel-identical |
|---|---|---|
| crospang | 10 | 10 |
| heuksun | 24 | 24 |
| bestri | 24 | 24 |
| bestria | 24 | 24 |
| pitapat | 24 | 24 |
| pitapata | 24 | 24 |
| crospang, 20 consecutive frames (290-309, flashing sprites) | 20 | 20 |

Line budget: 6,144 clocks; the longest line seen in these states is 3,637 clocks (Cross Pang frame 300).

**Final build** (video RAM snapshot, row reuse; `CROSPANG_BDIR=$HOME/build_crospang4`), every picture written fresh by that run
(`corpus_rtl.py` deletes a state's old pictures first and names the first picture after the load frame 1 with `+foff=-1`): the 150 states
above again, plus every 8th state of the four long scripted-play captures (Cross Pang, Heuk Sun, Bestri, Pitapat: 37 each) --
**298 of 298 states pixel-identical**.

## The video RAM snapshot (`tools/lua/vwrites.lua`)

All four games rewrite their whole sprite list and both tilemaps every frame, after the vertical blank interrupt:

| set (frames 600-900) | palette | sprite RAM | FG RAM | BG RAM | scroll / bank registers |
|---|---|---|---|---|---|
| crospang | 62-422 us | 446-1878 us | 1893-3324 us | 3331-4763 us | 43-52 us |
| heuksun | 53-1173 us | 88-2620 us | 2637-4065 us | 4075-5503 us | 39-73 us |
| bestri | 53-1171 us | 69-2600 us | 1516-2952 us | 2955-4390 us | 39-11711 us |
| pitapat | 67-621 us | 75-1348 us | 68-2075 us | 189-2802 us | 23-3709 us |

MAME draws the whole frame at the start of vertical blank, before any of that; a 15 kHz raster's vertical blank (20 lines, 1.28 ms here)
is shorter. The core copies the tile and sprite RAMs and the scroll / bank registers at the start of vertical blank (1024 clocks,
11 us; the earliest write the games make is 23 us after the interrupt) and draws the next frame from the copy: OSD **Video RAM: At vblank
(MAME)** (default). **Live** draws from the RAMs as they are. The palette is always looked up live, as the board's DAC path does.

## Whole machine from reset (`sim/run.sh`, `tools/sys_match.py`)

Cross Pang from reset with MAME's input log (`dump_state.lua` INPUTLOG: coin at frame 200, start at 260, scripted play), every picture
from frame 58 against MAME's picture of the same frame (`work/states/crospang_all`).

Frame numbering (`sim/tb_main.cpp`): MAME's first vertical blank is its frame 0 (its 512-line raster starts vertical blank at line 240,
round(240 / 512) = 0); the core's picture ending at its vertical blank n shows the snapshot taken at vertical blank n - 1, i.e. MAME's
frame n - 2 (`+foff`, default -2; -1 with `+live`; confirmed by the colour test, whose pictures change every second frame).
Inputs: a value `dump_state.lua` sets in its frame notifier f - 1 (logged as frame f) is first read by MAME's game after its vertical
blank f (`tools/lua/inreads.lua`: the start set in notifier 260 is first read in frame 261), which is the core's vertical blank f + 1
(`+ioff`, default 1).

**Cross Pang, frames 58..263 (boot colour test, title, coin at 200), first run (inputs one frame early, `+ioff=0`):** every picture is
pixel-identical to MAME's picture of the same frame **except during palette animations**: the boot colour test's fade steps (frames
59-63, 72-74, 83-84, 101-103, 112-116, 125-129, 138-142, ...) and the title screen's palette cycling (e.g. 177, 199: the core's picture
equals MAME's of the frame before, exactly). Tile and sprite content match throughout. Checked: in those frames the core's palette holds
values MAME computes too but one fade step later or earlier (MAME writes entry 0x11C once per step, ~465 us after the interrupt, inside
the core's vertical blank as well), so the game's main loop -- not the video -- reaches the next fade step at a slightly different time.
`+cpustats`: no cache line fills in those frames and DTACK ~5 clocks after AS, i.e. no wait states; what remains is the raster's
60.096 Hz (26 us less per frame than MAME's 60.000 Hz) and fx68k's cycle timing against MAME's 68000. A 60 Hz raster with MAME's vertical
blank phase (`VFLAGS=-DSIM_RASTER_60HZ` + `+mameraster`) changes which fade frames differ but does not remove them (its 10-line vertical
blank is shorter than the colour test's palette writes, so it is not a clean test either). Not chased further: the real board's
refresh rate is not known, and none of this changes the game.

After the start press (frame 260) the first run diverged in one sprite (the face in the title's "O", 582 pixels, every frame from 264):
the input arrived one frame early, which is what led to the `+ioff` measurement above.

**Cross Pang rerun with `+ioff=1` (frames 190..311):** the start press is followed by four transition frames that differ (261, 262,
264, 265: 2,146-4,036 pixels; the core reacts in the frame next to MAME's), and then **every frame from 266 to 311 -- 46 consecutive
frames of the mode select and the start of play -- is pixel-identical to MAME's picture of the same frame**. Before the start press
the differences are the title screen's palette steps as above. 313 frames from reset, no line over its budget (longest 3,054 of 6,144
clocks). Audio of the same run against MAME's recording (3.45-5.15 s, the coin sound and the OKI music): envelope correlation 0.989,
level within 0.2 dB. The four transition frames are the same with the 60 Hz raster in MAME's vertical blank phase (identical pixel
counts), so they are not the frame rate: they come from where in the frame the game samples the start input, and the picture is MAME's
again two frames later.  `docs/crospang_sim_frame300.png` is the core's picture of frame 300 in that run (byte-identical to MAME's).

**Pitapat Puzzle (14.318 MHz 68000), frames 58..84:** every picture is **pixel-identical to MAME's picture of the next frame** (n + 1),
from the first compared frame on, with the 60.096 Hz raster and with the 60 Hz raster in MAME's phase alike: the whole sequence is
exact and starts one frame earlier -- a start-up routine that ends just before a vertical blank in the core and just after one in MAME.

## Sound (`tools/cmp_audio.py`; MAME recordings at 48 kHz with `-wavwrite`)

| check | result |
|---|---|
| OKI M6295, boot sound (Cross Pang 0.05-0.95 s, whole-machine run; the YM3812 is silent there) | sample correlation 0.964 with MAME's recording; level: MAME = 0.94 x the core's (-0.5 dB) with the core's 16 x jt6295 sum (the level the owner measured for ohmygod) |
| the Z80's YM3812 traffic (`+cpustats` vs `tools/lua/ymlog.lua`) | the same as MAME's frame by frame: a 230-pair initialisation burst, one pair per frame (two every fifth), a 460-pair burst at frames 22-24 |
| when the games use the YM3812 (`ymlog.lua`, 60 s of scripted play) | Cross Pang: no key-on before 6.04 s (frame 362), then 1,779 key-ons in a minute incl. the rhythm section (register BD); Heuk Sun 381, Bestri 896, Pitapat 387: all four use it |
| YM3812 (jtopl2) against MAME's YM3812 alone (`tools/lua/fmonly.lua`: the OKI's sample ROM filled with 0x08, i.e. silenced), MAME's register writes replayed into jtopl2 at their times (`sim/run_opl.sh`), 6.1-11.5 s of Cross Pang's music | lag 0, envelope correlation 0.986, sample correlation 0.733 (two FM implementations: ymfm and jtopl); RMS 5,317 (core) vs 4,973 (MAME): the core 0.6 dB louder |

So the top level's mix (`Crospang.sv`: YM3812 + 16 x OKI, clipped, both at MAME's route 1.0) is MAME's within about 0.6 dB per chip.

## Build (Quartus Prime Lite 17.0.2, `quartus_sh --flow compile Crospang`, 29 min)

| | |
|---|---|
| ALMs | 12,968 / 41,910 (31 %) |
| block memory | 258 / 553 RAM blocks (47 %) |
| DSP | 36 / 112 |
| PLLs | 3 / 6 |
| setup slack, core clock (96 MHz) | +0.221 ns; all hold slacks > 0.24 ns |
| `tools/check_ram_depth.py` | 0 problems (every memory built as deep as the RTL declares it) |

The first build missed 96 MHz by 0.45 ns inside jtopl (slot counter -> output accumulator); both change only on jtopl's internal
enable (every 107 clocks), so `Crospang.sdc` gives those paths two clocks.

The second build (the controls above; 21 min): 12,939 ALMs, the same RAM blocks and DSPs, setup slack +0.085 ns, all hold slacks
> 0.24 ns, RAM depths OK. The third (the button order) was superseded before it finished.

The fourth build (button order, Scale, fast load, the CRT Adjust gate; 23 min): 13,350 ALMs (32 %), 260 RAM blocks (the fast load's
block buffer), 36 DSPs; setup slack at 96 MHz +0.441 ns, all hold slacks > 0.24 ns, no negative slack; RAM depths OK.
`releases/crospang_20261019.rbf` is that build (it replaced the earlier ones).
