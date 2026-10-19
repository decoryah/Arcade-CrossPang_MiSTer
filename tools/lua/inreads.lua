-- Logs the 68000's reads of the input ports (280000 P1_P2, 280002 COIN) with the frame, the time after the start of vertical blank and
-- the value read, for a range of frames, with the same scripted inputs as dump_state.lua (SCHEDULE=play: coin at 200, start at 260).
--   RFRAMES=a-b (default 255-275)   RLOG=<file>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.RKEEP = KEEP
local a, b = string.match(os.getenv("RFRAMES") or "255-275", "^(%d+)%-(%d+)$")
a, b = tonumber(a), tonumber(b)
local log = assert(io.open(os.getenv("RLOG") or "inreads.log", "w"))
local function t() local x = mach.time; return (type(x) == "number") and x or x:as_double() end
local function absframe() return math.floor(t() * 60 + 0.5) end
local f = absframe()
local vbl_t = 0
KEEP.r = sp:install_read_tap(0x280000, 0x280003, "inputs", function(off, data, mask)
  if f >= a and f <= b then
    log:write(string.format("%d %06x %04x %.1f\n", f, off, data & 0xffff, (t() - vbl_t) * 1e6))
  end
end)
-- the same scripted inputs as dump_state.lua's SCHEDULE=play (coin / start only: no play input before frame 330)
local function find_field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do if name == fname then return fld end end
end
local coin, start = find_field(":COIN", "Coin 1"), find_field(":P1_P2", "1 Player Start")
KEEP.n = emu.add_machine_frame_notifier(function()
  f = absframe()
  vbl_t = t()
  local cn = (f >= 200) and ((f - 200) % 1800 < 6)
  local st = (f >= 260) and ((f - 260) % 1800 < 6)
  coin:set_value(cn and 1 or 0); start:set_value(st and 1 or 0)
  if f > b then log:close(); mach:exit() end
end)
