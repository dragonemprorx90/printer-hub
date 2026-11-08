# /// script
# requires-python = ">=3.12"
#
# [tool.orcaslicer.plugin]
# name = "Printer Hub"
# description = "Your printers' live status beside the 3D view, from the Printer Hub Mac app. Send prints with the Printer Hub physical printer."
# author = "Printer Hub"
# version = "1.0.0"
# ///
"""Printer Hub for OrcaSlicer 2.5+.

Needs the Printer Hub Mac app running (it serves http://127.0.0.1:7126). The
panel lists every printer in Printer Hub with its state, progress and
temperatures, refreshed every 5 s. To send prints, add a physical printer in
Orca: host type "Octo/Klipper", host http://127.0.0.1:7126 (or
http://127.0.0.1:7126/<printer-name> to skip the printer question); Printer
Hub then uploads it, at home or from away, and opens its print setup.

Orca asks once to let this plugin reach 127.0.0.1; nothing else is contacted.
"""
import json
import urllib.request

import orca

HUB = "http://127.0.0.1:7126"

PAGE = """
<style>
  body { margin: 0; padding: 12px; font-size: 13px; }
  h3 { margin: 0 0 8px; font-size: 14px; }
  .p { border: 1px solid var(--orca-border); border-radius: 8px; padding: 8px 10px; margin-bottom: 8px; }
  .row { display: flex; justify-content: space-between; gap: 8px; }
  .name { font-weight: 700; }
  .muted { color: var(--orca-muted); font-size: 12px; }
  .bar { height: 5px; border-radius: 3px; background: var(--orca-border); margin-top: 6px; overflow: hidden; }
  .bar > div { height: 100%; background: var(--orca-accent, #339cff); }
  #status { color: var(--orca-muted); font-size: 12px; }
</style>
<h3>Printer Hub</h3>
<div id="list"></div>
<p id="status">Connecting to the Printer Hub app…</p>
<script>
(function () {
  function esc(v) { var s = document.createElement("span"); s.textContent = v == null ? "" : String(v); return s.innerHTML; }
  function dur(s) { if (!s) return ""; var h = Math.floor(s / 3600), m = Math.round(s % 3600 / 60); return h ? h + " h " + m + " min" : m + " min"; }
  orca.onMessage(function (m) {
    if (!m || m.command !== "printers") return;
    var st = document.getElementById("status");
    if (m.error) { document.getElementById("list").innerHTML = ""; st.textContent = m.error; return; }
    document.getElementById("list").innerHTML = m.printers.map(function (p) {
      var active = p.state === "printing" || p.state === "paused";
      return '<div class="p"><div class="row"><span class="name">' + esc(p.name) + '</span><span class="muted">' +
        (p.online ? esc(p.state) : "offline") + '</span></div>' +
        '<div class="muted">' + Math.round(p.hotend) + '° / ' + Math.round(p.bed) + '°' +
        (active ? ' · ' + Math.round(p.progress * 100) + '% · ' + dur(p.eta) + ' left' : '') + '</div>' +
        (active ? '<div class="muted">' + esc((p.file || "").split("/").pop()) + '</div><div class="bar"><div style="width:' +
          Math.round(p.progress * 100) + '%"></div></div>' : '') + '</div>';
    }).join("");
    st.textContent = "Updated " + new Date().toLocaleTimeString();
  });
  function tick() { orca.postMessage({ command: "refresh" }); }
  tick();
  setInterval(tick, 5000);
})();
</script>
"""


def fetch_printers():
    try:
        with urllib.request.urlopen(HUB + "/hub/printers", timeout=2) as r:
            return {"command": "printers", "printers": json.loads(r.read().decode("utf-8"))}
    except Exception:
        return {"command": "printers",
                "error": "Printer Hub isn't answering. Open the Printer Hub app (Settings → Orca Slicer link on)."}


class PrinterHubPanel(orca.script.ScriptPluginCapabilityBase):
    panel = None

    def get_name(self):
        return "Printer Hub"

    def execute(self):
        if self.panel is not None and self.panel.is_open():
            self.panel.show()
            return orca.ExecutionResult.success("Printer Hub is already open.")
        self.panel = orca.host.ui.create_dock_panel(
            html=PAGE, title="Printer Hub", width=300, height=520,
            on_message=self.on_message, on_close=self.on_close, dock="right")
        return orca.ExecutionResult.success("Printer Hub opened.")

    def on_message(self, message):
        if (message or {}).get("command") == "refresh" and self.panel is not None:
            self.panel.post(fetch_printers())

    def on_close(self):
        self.panel = None


@orca.plugin
class PrinterHubPlugin(orca.base):
    def register_capabilities(self):
        orca.register_capability(PrinterHubPanel)
