-- Freezes frames of the crospang.cpp games and writes everything the reference renderer needs, together with the exact pixels
-- MAME drew for that frame (screen:pixels(), 320 x 240).
--
--   DUMPFRAMES=<f,f,f...>  machine frames to capture (the vertical blank that ends frame f; also a range a-b/step as "a-b/s")
--   DUMPDIR=<dir>          output directory
--   SCHEDULE=play|none     scripted inputs: play = coin / start / random joystick and buttons (default none)
--   SEED=<n>               seed of the random play
--   COIN_FRAME=<n>, START_FRAME=<n>, PLAY_FRAME=<n>   (defaults 200, 260, 330)
--   INPUTLOG=<file>        the port values the 68000 reads, per frame, as "frame p1p2 coin" lines when they change
--   WRLOG=<file>           log of the 68000's writes to 0x100000-0x10000f: frame addr data mask
--
-- For every captured frame <N>:
--   f<N>.regs     frame, then the eight 16-bit registers at 0x100000,0x100002,..,0x10000e (raw, as last written),
--                 then tilebank[0..3] and the tile bank select (as the driver derives them from the writes at 0x100000 / 0x10000e)
--   f<N>.fg       0x120000-0x1207ff, one 16-bit word per line (hex)
--   f<N>.bg       0x122000-0x1227ff
--   f<N>.pal      0x200000-0x2005ff (0x300 words)
--   f<N>.spr      0x210000-0x2107ff (0x400 words)
--   f<N>.rgb      320 x 240 x 3 bytes, the frame MAME drew from exactly this state (taken one callback later)
--   f<N>.pal1     the palette one callback later (MAME converts pen indexes to RGB when the pixels are read)
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local KEEP = {}
_G.DUMPKEEP = KEEP

local DIR = os.getenv("DUMPDIR") or "."

local function combine(old, data, mask) return ((old & ~mask) | (data & mask)) & 0xffff end

local function absframe()
  local t = mach.time
  t = (type(t) == "number") and t or t:as_double()
  return math.floor(t * 60 + 0.5)
end
local f = absframe()

-- registers 0x100000..0x10000f: raw values as last written, plus the tile bank state of the driver
-- (tilebank_select_w at 0x100000: sel = (data >> 8) & 3;  tilebank_data_w at 0x10000e: bank[sel] = data >> 8, 8 bits)
local R = { 0, 0, 0, 0, 0, 0, 0, 0 }
local bank = { 0, 1, 2, 3 }
local banksel = 0
local wrlog
if os.getenv("WRLOG") then wrlog = assert(io.open(os.getenv("WRLOG"), "w")) end

KEEP.t1 = sp:install_write_tap(0x100000, 0x10000f, "regs", function(off, data, mask)
  -- `off` is the byte address (0x100000 + n); a 16-bit write has an even address, a byte write uses the mask
  local a = off & 0xe
  local i = (a >> 1) + 1
  R[i] = combine(R[i], data, mask)
  if a == 0x0 and (mask & 0xff00) ~= 0 then banksel = (data >> 8) & 3 end
  if a == 0xe and (mask & 0xff00) ~= 0 then bank[banksel + 1] = (data >> 8) & 0xff end
  if wrlog then wrlog:write(string.format("%d %06x %04x %04x\n", f, off, data & 0xffff, mask & 0xffff)) end
end)

-- frame list
local FRAMES = {}
local LAST = 0
for item in string.gmatch(os.getenv("DUMPFRAMES") or "300", "[^,]+") do
  local a, b, s = string.match(item, "^(%d+)%-(%d+)/(%d+)$")
  if a then
    for n = tonumber(a), tonumber(b), tonumber(s) do FRAMES[n] = true; if n > LAST then LAST = n end end
  else
    local n = tonumber(item); FRAMES[n] = true; if n > LAST then LAST = n end
  end
end

local function words(base, count, path)
  local o = assert(io.open(path, "w"))
  local t = {}
  for i = 0, count - 1 do t[i + 1] = string.format("%04x", sp:read_u16(base + i * 2)) end
  o:write(table.concat(t, "\n"), "\n")
  o:close()
end

-- screen:pixels() is 32-bit ARGB, little-endian (bytes B, G, R, A)
local pending
local function dump_pixels(path)
  local px = scr:pixels()
  local out = {}
  local n = #px // 4
  for i = 0, n - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  local o = assert(io.open(path, "wb"))
  o:write(table.concat(out))
  o:close()
end

local function dump()
  local pre = string.format("%s/f%05d", DIR, f)
  local o = assert(io.open(pre .. ".regs", "w"))
  o:write(string.format("%d %04x %04x %04x %04x %04x %04x %04x %04x %d %d %d %d %d\n", f,
    R[1], R[2], R[3], R[4], R[5], R[6], R[7], R[8], bank[1], bank[2], bank[3], bank[4], banksel))
  o:close()
  words(0x120000, 0x400, pre .. ".fg")
  words(0x122000, 0x400, pre .. ".bg")
  words(0x200000, 0x300, pre .. ".pal")
  words(0x210000, 0x400, pre .. ".spr")
  -- the frame notifier runs before the screen is updated, so screen:pixels() still holds the PREVIOUS frame here
  pending = pre
  print("DUMPED frame " .. tostring(f))
  io.stdout:flush()
end

-- scripted inputs: find the fields by their type/name so a wrong name does not abort the run
local function find_field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do
    if name == fname then return fld end
  end
  return nil
end
local coin, start = find_field(":COIN", "Coin 1"), find_field(":P1_P2", "1 Player Start")
local up, dn, lf, rt = find_field(":P1_P2", "P1 Up"), find_field(":P1_P2", "P1 Down"), find_field(":P1_P2", "P1 Left"), find_field(":P1_P2", "P1 Right")
local b1, b2 = find_field(":P1_P2", "P1 Button 1"), find_field(":P1_P2", "P1 Button 2")
local b3 = os.getenv("B3") and find_field(":P1_P2", "P1 Button 3")   -- B3=1: also press button 3 (pitapat's), see below
local B3_AT = tonumber(os.getenv("B3_AT") or "")                     -- with B3=1: only at frames B3_AT..B3_AT+3 (default every 29)
local SCHED       = os.getenv("SCHEDULE") or "none"
local COIN_FRAME  = tonumber(os.getenv("COIN_FRAME") or "200")
local START_FRAME = tonumber(os.getenv("START_FRAME") or "260")
local PLAY_FRAME  = tonumber(os.getenv("PLAY_FRAME") or "330")
local rng = tonumber(os.getenv("SEED") or "12345")
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local dir = 0
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end

local inlog
if os.getenv("INPUTLOG") then inlog = assert(io.open(os.getenv("INPUTLOG"), "w")) end
local last1, last2 = -1, -1

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = absframe()
  if pending then
    dump_pixels(pending .. ".rgb")
    words(0x200000, 0x300, pending .. ".pal1")
    pending = nil
  end
  local cn, st, du, dd, dl, dr, bt, bt2, bt3 = false, false, false, false, false, false, false, false, false
  if SCHED == "play" then
    cn = (f >= COIN_FRAME) and ((f - COIN_FRAME) % 1800 < 6)
    st = (f >= START_FRAME) and ((f - START_FRAME) % 1800 < 6)
    if f >= PLAY_FRAME then
      if f % 10 == 0 then dir = rnd(5) end
      du = (dir == 1); dd = (dir == 2); dl = (dir == 3); dr = (dir == 4)
      bt = (f % 23 < 5)
      bt2 = (f % 37 < 4)
      if b3 then
        if B3_AT then bt3 = (f >= B3_AT and f < B3_AT + 4) else bt3 = (f % 29 < 4) end
      end
    end
    setv(coin, cn); setv(start, st)
    setv(up, du); setv(dn, dd); setv(lf, dl); setv(rt, dr); setv(b1, bt); setv(b2, bt2); setv(b3, bt3)
  end
  if inlog then
    local v1, v2 = 0xffff, 0xffff
    if st  then v1 = v1 & ~0x0080 end
    if du  then v1 = v1 & ~0x0001 end
    if dd  then v1 = v1 & ~0x0002 end
    if dl  then v1 = v1 & ~0x0004 end
    if dr  then v1 = v1 & ~0x0008 end
    if bt  then v1 = v1 & ~0x0010 end
    if bt2 then v1 = v1 & ~0x0020 end
    if bt3 then v1 = v1 & ~0x0040 end
    if cn  then v2 = v2 & ~0x0100 end
    if v1 ~= last1 or v2 ~= last2 then inlog:write(string.format("%d %04x %04x\n", f + 1, v1, v2)); last1, last2 = v1, v2 end
  end
  if FRAMES[f] then dump() end
  if f >= LAST + 1 then
    if wrlog then wrlog:close() end
    if inlog then inlog:close() end
    mach:exit()
  end
end)
