-- Prints the value of every input port (MAME's defaults: no input, DIP switches at their default settings) and the fields of each,
-- then exits.  Used for the bench's +dsw= and the MRA's switch defaults.
local mach = manager.machine
local done = false
emu.add_machine_frame_notifier(function()
  if done then return end
  done = true
  for tag, port in pairs(mach.ioport.ports) do
    print(string.format("PORT %s %04x", tag, port:read()))
    for name, fld in pairs(port.fields) do
      print(string.format("  FIELD %s mask=%04x defvalue=%04x", name, fld.mask, fld.defvalue))
    end
  end
  mach:exit()
end)
