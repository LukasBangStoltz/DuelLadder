"""Checks the row of tabs fits inside the window for both tab styles."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "sim.py"), encoding="utf-8").read()
exec(src.split("# --- 1. Login and sync")[0])   # only the harness, not the scenarios
for template, spacing in [("PanelTabButtonTemplate", 3), ("CharacterFrameTabButtonTemplate", -16)]:
    c = Client("Anna", "WARRIOR", 70, extra=f'''
      C_XMLUtil = {{ GetTemplateInfo = function(n) if n == "{template}" then return {{}} end end }}
      RESIZED = {{}}
      function PanelTemplates_TabResize(tab, pad, w) RESIZED[#RESIZED+1] = w end
      local orig = CreateFrame
      function CreateFrame(t, name, parent, tmpl)
        local f = orig(t, name, parent, tmpl)
        if name and name:match("^DuelLadderFrameTab") then
          local fs = orig(); rawset(fs, "GetStringWidth", function() return 60 end)
          rawset(f, "GetFontString", function() return fs end)
          local left = orig(); rawset(left, "GetWidth", function() return 35 end)
          rawset(f, "Left", left)
        end
        return f
      end
    ''')
    c.run("ADVANCE(5); NS.UI:Toggle()")
    w = max(c.eval("RESIZED").values())
    end_px = 10 + 6 * w + spacing * 5
    check(end_px <= 750, f"{template}: tabs are {w}px each and end at {end_px}px inside the 760px window")
print()
print(f"{failures} failure(s)")
