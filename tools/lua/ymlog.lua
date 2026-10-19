-- Logs the Z80's YM3812 register writes (address / data pairs, ports 00 / 01) with the machine time, and reports the key-ons
-- (registers B0-B8 with bit 5 set) per second, for YSECONDS seconds (default 6).  Same scripted inputs as dump_state.lua's play schedule.
--   YLOG=<file>   all writes as "time reg data"
local mach = manager.machine
local zio  = mach.devices[":audiocpu"].spaces["io"]
local KEEP = {}
_G.YKEEP = KEEP
local secs = tonumber(os.getenv("YSECONDS") or "6")
local log = assert(io.open(os.getenv("YLOG") or "ymlog.txt", "w"))
local reg = 0
local kon = {}
local function t() local x = mach.time; return (type(x) == "number") and x or x:as_double() end
KEEP.w = zio:install_write_tap(0x00, 0x01, "ym", function(off, data, mask)
  if (off & 1) == 0 then reg = data & 0xff
  else
    log:write(string.format("%.6f %02x %02x\n", t(), reg, data & 0xff))
    if reg >= 0xb0 and reg <= 0xb8 and (data & 0x20) ~= 0 then
      local s = math.floor(t())
      kon[s] = (kon[s] or 0) + 1
    end
  end
end)
local function find_field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do if name == fname then return fld end end
end
local coin, start = find_field(":COIN", "Coin 1"), find_field(":P1_P2", "1 Player Start")
KEEP.n = emu.add_machine_frame_notifier(function()
  local f = math.floor(t() * 60 + 0.5)
  coin:set_value(((f >= 200) and ((f - 200) % 1800 < 6)) and 1 or 0)
  start:set_value(((f >= 260) and ((f - 260) % 1800 < 6)) and 1 or 0)
  if t() > secs then
    for s = 0, secs do print(string.format("KEYON second %d: %d", s, kon[s] or 0)) end
    log:close()
    mach:exit()
  end
end)
