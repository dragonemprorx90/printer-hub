# /// script
# requires-python = ">=3.12"
#
# [tool.orcaslicer.plugin]
# name = "Printer Hub"
# description = "Your printers beside the 3D view: live status, loaded filaments, light / pause / resume / cancel, and Use this printer, which loads its Orca printer preset, connection and filaments. Uses the Printer Hub Mac app."
# author = "Printer Hub"
# version = "1.3.0"
# type = "script"
# ///
"""Printer Hub for OrcaSlicer 2.5+.

Needs the Printer Hub Mac app (it serves http://127.0.0.1:7126; nothing else
is contacted). Orca asks once to allow 127.0.0.1.

- Devices: every printer in Printer Hub with state, progress, temperatures and
  its loaded filaments (U1 lanes, K2 CFS), refreshed every 5 s, also from away.
- Controls: light, pause, resume, cancel.
- Use this printer: selects the matching Orca printer preset (bed size, nozzles,
  extruders), points its connection at Printer Hub's local Moonraker for that
  printer (127.0.0.1:7130, 7131, ...; works at home and from away) with Orca's
  own agent (Snapmaker for the U1, Moonraker for the K2) and sets each filament slot
  to the loaded material. Then Orca's sync button next to "Filament" loads the
  exact colours. Orca 2.5's plugin API can't set slot colours itself.
- Sending prints: add a physical printer in Orca, host type "Octo/Klipper",
  host 127.0.0.1:7126/<printer-name>; Printer Hub uploads and opens print setup.
"""
import asyncio
import json
import queue
import urllib.request

import orca

HUB = "http://127.0.0.1:7126"

PAGE = """
<style>
  body { margin: 0; padding: 12px; font-size: 13px; }
  h3 { margin: 0 0 8px; font-size: 14px; }
  .p { border: 1px solid var(--orca-border); border-radius: 8px; padding: 8px 10px; margin-bottom: 10px; }
  .row { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .name { font-weight: 700; }
  .muted { color: var(--orca-muted); font-size: 12px; }
  .pill { font-size: 11px; padding: 1px 6px; border-radius: 9px; border: 1px solid var(--orca-border); }
  .bar { height: 5px; border-radius: 3px; background: var(--orca-border); margin-top: 6px; overflow: hidden; }
  .bar > div { height: 100%; background: var(--orca-accent, #339cff); }
  .fil { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
  .chip { display: flex; align-items: center; gap: 4px; font-size: 11px; }
  .dot { width: 14px; height: 14px; border-radius: 50%; border: 1px solid var(--orca-border); }
  .actions { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 8px; }
  .actions button { font-size: 11px; padding: 2px 8px; }
  #status { color: var(--orca-muted); font-size: 12px; }
</style>
<h3>Printer Hub</h3>
<div id="list"></div>
<p id="status">Connecting to the Printer Hub app…</p>
<script>
(function () {
  function esc(v) { var s = document.createElement("span"); s.textContent = v == null ? "" : String(v); return s.innerHTML; }
  function dur(s) { if (!s) return ""; var h = Math.floor(s / 3600), m = Math.round(s % 3600 / 60); return h ? h + " h " + m + " min" : m + " min"; }
  function act(slug, what) { orca.postMessage({ command: "action", printer: slug, action: what }); }
  window.phAct = function (slug, what, name) {
    if (what === "cancel" && !confirm("Cancel the print on " + name + "?")) return;
    act(slug, what);
  };
  window.phSync = function (slug) { orca.postMessage({ command: "sync", printer: slug }); };
  orca.onMessage(function (m) {
    var st = document.getElementById("status");
    if (!m) return;
    if (m.command === "note") { st.textContent = m.text; return; }
    if (m.command !== "printers") return;
    if (m.error) { document.getElementById("list").innerHTML = ""; st.textContent = m.error; return; }
    document.getElementById("list").innerHTML = m.printers.map(function (p) {
      var active = p.state === "printing" || p.state === "paused";
      var fil = (p.filaments || []).map(function (f) {
        return '<span class="chip"><span class="dot" style="background:' + (f.color || "transparent") + '"></span>' +
          esc(f.label) + " " + esc(f.material || "empty") + '</span>';
      }).join("");
      var s = esc(p.slug), n = esc(p.name);
      return '<div class="p"><div class="row"><span class="name">' + n + '</span><span class="pill">' +
        (p.online ? esc(p.state) : "offline") + '</span></div>' +
        '<div class="muted">' + Math.round(p.hotend) + '° nozzle · ' + Math.round(p.bed) + '° bed' +
        (active ? ' · ' + Math.round(p.progress * 100) + '% · ' + dur(p.eta) + ' left' : '') + '</div>' +
        (active ? '<div class="muted">' + esc((p.file || "").split("/").pop()) + '</div><div class="bar"><div style="width:' +
          Math.round(p.progress * 100) + '%"></div></div>' : '') +
        (fil ? '<div class="fil">' + fil + '</div>' : '') +
        '<div class="actions">' +
          (p.model ? '<button onclick="phSync(\\'' + s + '\\')">Use this printer in Orca</button>' : '') +
          (p.light != null ? '<button onclick="phAct(\\'' + s + '\\',\\'light\\')">Light ' + (p.light ? 'off' : 'on') + '</button>' : '') +
          (p.state === "printing" ? '<button onclick="phAct(\\'' + s + '\\',\\'pause\\')">Pause</button>' : '') +
          (p.state === "paused" ? '<button onclick="phAct(\\'' + s + '\\',\\'resume\\')">Resume</button>' : '') +
          (active ? '<button onclick="phAct(\\'' + s + '\\',\\'cancel\\',\\'' + n + '\\')">Cancel</button>' : '') +
        '</div></div>';
    }).join("");
    st.textContent = "Updated " + new Date().toLocaleTimeString();
  });
  function tick() { orca.postMessage({ command: "refresh" }); }
  tick();
  setInterval(tick, 5000);
})();
</script>
"""


def _get(path):
    with urllib.request.urlopen(HUB + path, timeout=3) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_printers():
    try:
        return {"command": "printers", "printers": _get("/hub/printers")}
    except Exception:
        return {"command": "printers",
                "error": "Printer Hub isn't answering. Open the Printer Hub app (Settings → Orca Slicer on)."}


def do_action(slug, action):
    req = urllib.request.Request(HUB + "/hub/action?printer=" + slug + "&do=" + action, data=b"",
                                 method="POST", headers={"X-Printer-Hub": "1"})
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


def _first(value):
    if isinstance(value, (list, tuple)):
        return str(value[0]) if value else ""
    return "" if value is None else str(value)


def _preset_for(material, current):
    """Current preset if it is that material, else the first visible compatible one that is."""
    bundle = orca.host.preset_bundle()
    filaments = bundle.filaments

    def material_of(name):
        p = filaments.find_preset(name)
        return _first(p.config_value("filament_type")).upper() if p is not None else ""

    if current and material_of(current) == material.upper():
        return current
    for name in filaments.preset_names():
        p = filaments.find_preset(name)
        if p is not None and p.is_visible and p.is_compatible and material_of(name) == material.upper():
            return name
    return current


def _printer_preset(model):
    """The Orca printer preset for this model, preferring a 0.4 nozzle."""
    words = model.lower().split()
    names = [n for n in orca.host.preset_bundle().printers.preset_names()
             if all(w in n.lower() for w in words)]
    names.sort(key=lambda n: ("0.4" not in n, len(n)))
    return names[0] if names else None


def use_printer(slug):
    """Runs on the Script worker (preset edits are not allowed on the UI thread)."""
    printer = next((p for p in _get("/hub/printers") if p["slug"] == slug), None)
    if printer is None:
        return "That printer is gone from Printer Hub."
    preset = _printer_preset(printer.get("model", ""))
    if preset is None:
        return "Orca has no %s printer preset. Add it in Orca's printer list first." % printer.get("model")
    # Printer Hub's local Moonraker for this printer: reaches it at home and,
    # through the home bridge, from anywhere.
    host = printer.get("proxy") or "%s:%s" % (printer["host"], printer["port"])
    tx = orca.host.preset.printer.begin_update(preset_name=preset)
    tx.set("print_host", host)
    tx.set("host_type", printer.get("host_type", "moonraker"))
    tx.set("printer_agent", printer.get("agent", "moonraker"))
    tx.commit()
    # Filament slots: the loaded material (colour comes from Orca's own sync).
    slots = list(orca.host.preset_bundle().current_filament_preset_names())
    changed = []
    for f in printer.get("filaments", []):
        slot = f["tool"] + 1
        if not f.get("material") or slot > len(slots):
            continue
        want = _preset_for(f["material"], slots[slot - 1])
        if want and want != slots[slot - 1]:
            orca.host.preset.filament.begin_update(slot_number=slot, preset_name=want).commit()
            changed.append(str(slot))
    return ("Loaded %s, connected to %s." % (preset, host) +
            (" Filament slot %s set to the loaded material." % ", ".join(changed) if changed else "") +
            " Now press the sync button next to Filament for the colours.")


class PrinterHubPanel(orca.script.ScriptPluginCapabilityBase):
    panel = None
    jobs = None

    def get_name(self):
        return "Printer Hub"

    async def execute(self):
        if self.panel is not None and self.panel.is_open():
            self.panel.show()
            return orca.ExecutionResult.success("Printer Hub is already open.")
        self.jobs = queue.Queue()
        self.panel = orca.host.ui.create_dock_panel(
            html=PAGE, title="Printer Hub", width=320, height=600,
            on_message=self.on_message, on_close=self.on_close, dock="right")
        # This invocation stays alive while the panel is open: it is the Script
        # worker, the one place preset edits (colour sync) are allowed.
        while self.panel is not None:
            try:
                slug = self.jobs.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.2)
                continue
            try:
                text = use_printer(slug)
            except Exception as e:  # cancelled dialog, missing preset, Printer Hub closed
                text = "Stopped: %s" % e
            if self.panel is not None:
                self.panel.post({"command": "note", "text": text})
        return orca.ExecutionResult.success("Printer Hub closed.")

    # UI thread: quick local calls only; colour sync is handed to the worker.
    def on_message(self, message):
        message = message or {}
        command = message.get("command")
        if command == "refresh":
            self.panel.post(fetch_printers())
        elif command == "sync":
            self.panel.post({"command": "note", "text": "Loading the printer into Orca…"})
            self.jobs.put(message.get("printer", ""))
        elif command == "action":
            try:
                do_action(message.get("printer", ""), message.get("action", ""))
                self.panel.post(fetch_printers())
            except Exception as e:
                self.panel.post({"command": "note", "text": "Could not %s: %s" % (message.get("action"), e)})

    def on_close(self):
        self.panel = None


@orca.plugin
class PrinterHubPlugin(orca.base):
    def register_capabilities(self):
        orca.register_capability(PrinterHubPanel)
