-- Logs, for a range of frames, when (in microseconds after the start of vertical blank = the level 6 interrupt) the 68000 writes the
-- sprite RAM, the two video RAMs, the palette and the video registers.  Answers: does the game finish updating the picture's RAMs within
-- the core's 20-line vertical blank (1.28 ms), or does it keep writing while the picture is drawn (MAME draws the whole frame at the start
-- of vertical blank, so it never shows a half-written list)?
--   VFRAMES=a-b   frames to log (default 600-660)      VLOG=<file>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.VKEEP = KEEP
local a, b = string.match(os.getenv("VFRAMES") or "600-660", "^(%d+)%-(%d+)$")
a, b = tonumber(a), tonumber(b)
local log = assert(io.open(os.getenv("VLOG") or "vwrites.log", "w"))
local function t() local x = mach.time; return (type(x) == "number") and x or x:as_double() end
local function absframe() return math.floor(t() * 60 + 0.5) end
local f = absframe()
local vbl_t = 0                      -- time of the last vertical blank start
local stats = {}
local function tap(lo, hi, name)
  return sp:install_write_tap(lo, hi, name, function(off, data, mask)
    if f >= a and f <= b then
      local us = (t() - vbl_t) * 1e6
      local s = stats[name]
      if not s then s = { n = 0, max = 0, min = 1e9 }; stats[name] = s end
      s.n = s.n + 1
      if us > s.max then s.max = us end
      if us < s.min then s.min = us end
      log:write(string.format("%d %s %06x %.1f\n", f, name, off, us))
    end
  end)
end
KEEP[1] = tap(0x210000, 0x2107ff, "spr")
KEEP[2] = tap(0x120000, 0x1207ff, "fg")
KEEP[3] = tap(0x122000, 0x1227ff, "bg")
KEEP[4] = tap(0x200000, 0x2005ff, "pal")
KEEP[5] = tap(0x100000, 0x10000f, "reg")
KEEP.n = emu.add_machine_frame_notifier(function()
  f = absframe()
  vbl_t = t()
  if f > b then
    for name, s in pairs(stats) do
      print(string.format("WRITES %-4s %6d writes, from %.0f to %.0f us after the vertical blank starts", name, s.n, s.min, s.max))
    end
    log:close()
    mach:exit()
  end
end)
