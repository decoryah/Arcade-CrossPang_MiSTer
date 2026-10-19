-- Counts the Z80's I/O writes per port (00/01 YM3812, 02 OKI M6295) and its reads of the latch (06), per second of machine time,
-- for ZSECONDS seconds (default 6); prints the first writes to the YM3812.  Same scripted inputs as dump_state.lua's SCHEDULE=play.
local mach = manager.machine
local zio  = mach.devices[":audiocpu"].spaces["io"]
local KEEP = {}
_G.ZKEEP = KEEP
local secs = tonumber(os.getenv("ZSECONDS") or "6")
local cnt = {}
local first = 0
local function t() local x = mach.time; return (type(x) == "number") and x or x:as_double() end
KEEP.w = zio:install_write_tap(0x00, 0x02, "zw", function(off, data, mask)
  local s = math.floor(t())
  local k = string.format("%d w%02x", s, off & 0xff)
  cnt[k] = (cnt[k] or 0) + 1
  if (off & 0xff) <= 1 and first < 12 then
    print(string.format("YM write %.4f s port %02x data %02x", t(), off & 0xff, data & 0xff))
    first = first + 1
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
    local keys = {}
    for k in pairs(cnt) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do print("ZIO " .. k .. " " .. cnt[k]) end
    mach:exit()
  end
end)
