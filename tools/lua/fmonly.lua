-- MAME with the OKI M6295 silenced (its sample ROM filled with 0x08: nibbles 0 and 8, +/- the smallest step, which decodes to a
-- signal of a few LSBs), so that a -wavwrite recording holds the YM3812 alone; also logs the YM3812 register writes ("time reg data")
-- like ymlog.lua, with the same scripted inputs (coin 200, start 260).  YSECONDS (default 12), YLOG.
local mach = manager.machine
local r = mach.memory.regions[":oki"]
for i = 0, r.size - 1 do r:write_u8(i, 0x08) end
dofile(os.getenv("YMLOG_LUA"))
