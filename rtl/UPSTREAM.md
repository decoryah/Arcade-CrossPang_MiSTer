# Files in this directory derived from other projects

| File | Derived from | Licence | Changes for this core |
|---|---|---|---|
| `sdram_ctrl.sv` | the owner's `ohmygod-mister/mister/rtl/sdram_ctrl.sv` (from `mcatadv-mister`, itself the Pocket Gaiapolis core's multi-port controller by plasticbugs, carried to MiSTer, with the Punch-Out!! core's `sdram16.sv` pin-level behaviour) | GPL-3.0-or-later (`../LICENSE`) | none: byte-identical; used with two clients (OKI byte reads and the loader) and the burst port |
| `cp_ram.sv` | `omg_ram.sv` (from `mcatadv_ram.sv`: block RAMs written the way Quartus 17 infers M10K) | same | renamed |
| `cp_cache.sv` | `omg_cache.sv` (from `mcatadv_cache.sv`) | same | renamed; widened to the 1 MB program (6-bit tags) |
| `cp_video.sv` | `omg_video.sv` | same | renamed; the palette is xRGB555 |
| `cp_mem.sv` | `omg_mem.sv` (from `mcatadv_mem.sv`: loader, burst arbiter) | same | renamed; this board's image layout, the remap of the two graphics ROMs (a tile row = 4 adjacent words), the Z80 program and the configuration bytes taken off the stream; 4-word tile / sprite clients |
| `cp_crtadj.sv` | `omg_crtadj.sv` (the Metro core's `metro_crtadj.sv`: glue for rmonic79's CRT Adjust, `../modules/crt_adjust`) | same | renamed; same totals (`VTOTAL` 260, `HTOTAL` 384) |
| `pll.v`, `pll.qip`, `pll/` | the Metro core's PLL via `ohmygod-mister` (reference 50 MHz: 96 MHz machine clock, 96 MHz shifted for the SDRAM chip) | same | none |
| `cp_fastload.sv` | the fast load of the owner's Monster Maulers / Violent Storm cores (`mm_mem.sv`, `vs_mem.sv`: the MRA's `address=`, the empty download, 32-beat DDR3 blocks) | same | a module of its own that feeds the unchanged byte loader of `cp_mem.sv` as the HPS would |
| `../sim/sd/` | the owner's Monster Maulers core, `sim/emu/run_sd.sh`, `tb_sd_top.sv`, `tb_sd.cpp`, `sync_fix.sv` (the framework's scandoubler fed with the core's raster) | same | this core's raster and CRT Adjust, with and without the gate |

Written for this core (not derived): `cp_main.sv` (the 68000 board: memory map, RAMs, per-game scroll registers, tile banks, sound
latch; bus-cycle structure after `omg_main.sv`), `cp_render.sv` (the line renderer: two tilemaps and the DECO 52 sprites in bootleg mode;
structure after `omg_render.sv`, sprite logic from MAME's `decospr.cpp`, checked against `../../ref/Arcade-Deco16/jtcninja_decospr.v`),
`cp_sound.sv` (Z80, YM3812, OKI, latch), `cp_cen.sv` (clock enables from the 14.318 MHz crystal) and `cp_core.sv` (wiring).
The 68000 core (`../modules/cpu-fx68k`), the Z80 (`../modules/cpu-tv80`), the YM3812 (`../modules/jtopl`), the OKI
(`../modules/jt6295`) and the CRT Adjust page (`../modules/crt_adjust`) are vendored: `../modules/VENDOR.md`.
