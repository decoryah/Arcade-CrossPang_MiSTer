-- Does the game look at its service switch while it runs?  Logs the 68000's reads of the DSW port (0x280004) per frame and, from
-- frame SVC_ON to SVC_OFF, returns the port with the service switch on (SVC_MASK cleared: the switches are active low).
--
--   SVC_MASK=<hex>             the set's service switch (crospang 4000, heuksun 0080, bestri 0001, pitapat 0080)
--   SVC_ON=<n>, SVC_OFF=<n>    machine frames (default: never on)
--   DUMPFRAMES=<f,f,...>       MAME's picture of these frames, 320 x 240 x 3 bytes: DUMPDIR/f<N>.rgb
--   DUMPDIR=<dir>              also gets reads.log: "frame reads value" for every frame in which the game read the port
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.SVCKEEP = KEEP

local function absframe()
  local t = mach.time
  t = (type(t) == "number") and t or t:as_double()
  return math.floor(t * 60 + 0.5)
end

local MASK = tonumber(os.getenv("SVC_MASK") or "0", 16)
local ON   = tonumber(os.getenv("SVC_ON") or "-1")
local OFF  = tonumber(os.getenv("SVC_OFF") or "1000000000")
local DIR  = os.getenv("DUMPDIR") or "."
local FR, LAST = {}, 0
for item in string.gmatch(os.getenv("DUMPFRAMES") or "600", "[^,]+") do
  local n = tonumber(item); FR[n] = true; if n > LAST then LAST = n end
end

local f = absframe()
local reads, lastval = 0, 0
local log = assert(io.open(DIR .. "/reads.log", "w"))

KEEP.tap = sp:install_read_tap(0x280004, 0x280005, "dsw", function(off, data, mask)
  reads = reads + 1
  if MASK ~= 0 and ON >= 0 and f >= ON and f < OFF then data = data & ~MASK end
  lastval = data & 0xffff
  return data
end)

-- screen:pixels() is 32-bit ARGB, little-endian (bytes B, G, R, A); the notifier runs before the screen update, so the picture of
-- frame N is read in the next callback (as tools/lua/dump_state.lua does)
local function dump_pixels(path)
  local px = scr:pixels()
  local out = {}
  for i = 0, #px // 4 - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  local o = assert(io.open(path, "wb"))
  o:write(table.concat(out))
  o:close()
end

local pending
KEEP.notif = emu.add_machine_frame_notifier(function()
  if pending then dump_pixels(pending); pending = nil end
  if reads > 0 then log:write(string.format("%d %d %04x\n", f, reads, lastval)) end
  reads = 0
  f = absframe()
  if FR[f] then pending = string.format("%s/f%05d.rgb", DIR, f) end
  if f >= LAST + 1 then log:close(); mach:exit() end
end)
