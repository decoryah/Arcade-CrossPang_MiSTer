-- Writes every ROM region of the running set as MAME loaded it (raw bytes), to check tools/crospang_rom.py's images against.
--   REGDIR=<dir>   output directory (default: current); files <region>.bin
-- maincpu (as the 68000 sees it, big-endian words), audiocpu, oki, tiles, sprites.
local regs = manager.machine.memory.regions
local dir  = os.getenv("REGDIR") or "."
local plan = { ":maincpu", ":audiocpu", ":oki", ":tiles", ":sprites" }
for _, tag in ipairs(plan) do
  local r = regs[tag]
  if r == nil then
    print("MISSING " .. tag)
  else
    local name = tag:sub(2)
    local f = assert(io.open(dir .. "/" .. name .. ".bin", "wb"))
    local n = r.size
    local CH = 4096
    for base = 0, n - 1, CH do
      local t = {}
      local last = math.min(CH, n - base)
      for i = 0, last - 1 do t[i + 1] = string.char(r:read_u8(base + i)) end
      f:write(table.concat(t))
    end
    f:close()
    print(string.format("REGION %s size=%d", tag, n))
  end
end
print("REGIONS_DUMPED")
manager.machine:exit()
