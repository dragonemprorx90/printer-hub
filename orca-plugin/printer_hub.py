# /// script
# requires-python = ">=3.12"
#
# [tool.orcaslicer.plugin]
# name = "Printer Hub"
# description = "Your printers beside the 3D view: camera, progress, temperatures, controls, filaments and spools, history with pictures, rules and print alerts. Uses the Printer Hub Mac app."
# author = "Printer Hub"
# version = "3.3.0"
# type = "script"
# ///
"""Printer Hub for OrcaSlicer 2.5+.

Needs the Printer Hub Mac app (it serves http://127.0.0.1:7126; nothing else
is contacted). Orca asks once to allow 127.0.0.1.

- Opens by itself when Orca starts; after closing it, click "Open Printer Hub"
  in the notification (or run it from the Plugins dialog).
- Each printer: camera snapshot, layer / progress / finish time, temperatures,
  heater, loaded filaments (warns when Orca's slots don't match), its Orca
  connection address, and light / pause / resume / cancel.
- Controls: temperatures and preheat (from Orca's current filament), home,
  motors off, emergency stop, fans, speed, flow, Z offset, pause at layer,
  macros (PID, input shaper, bed mesh...), exclude object, DragonBreath drying,
  filter and fault clear, bed mesh range.
- History (recent prints, success rate, pictures, reprint), Spools (grams
  left, low warnings, link to a lane, add a spool for a lane), Rules (on/off).
- Alerts as Orca notifications: finished, failed, paused (e.g. run-out),
  chamber at temperature.
- Filament colours: connect the printer in Orca to the address on its card
  (host 127.0.0.1, port 7130...) and use Orca's own sync next to "Filament".
"""
import json
import time
import urllib.error
import urllib.parse
import urllib.request

import orca

HUB = "http://127.0.0.1:7126"

PAGE = r"""
<style>
  /* Tokens mirror lib/ui.dart; see docs/designs/ui-style.md */
  :root { --ph-danger: #FF5470; --ph-warn: #F5A524; --ph-border: var(--orca-border, #8884); --ph-muted: var(--orca-muted, #888); --ph-accent: var(--orca-accent, #339cff); }
  @media (prefers-color-scheme: light) { :root { --ph-danger: #C8243F; --ph-warn: #9A6200; } }
  body { margin: 0; padding: 12px; font-size: 13px; font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; }
  h3 { margin: 0; font-size: 14px; }
  .top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; gap: 8px; flex-wrap: wrap; }
  .top select, .top label { font-size: 12px; }
  .p { border: 1px solid var(--ph-border); border-radius: 12px; padding: 10px 12px; margin-bottom: 12px; }
  .p.is-err { border-left: 2px solid var(--ph-danger); }
  .p.is-paused { border-left: 2px solid var(--ph-warn); }
  .p.is-off { opacity: .6; }
  .row { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .name { font-weight: 700; font-size: 14px; }
  .muted { color: var(--ph-muted); font-size: 12px; }
  .warn { color: var(--ph-warn); font-size: 12px; }
  .err { font-size: 12px; border-left: 2px solid var(--ph-danger); padding-left: 6px; }
  .pill { font-size: 11px; padding: 1px 8px; border-radius: 99px; border: 1px solid var(--ph-border); }
  .badge { font-size: 11px; padding: 1px 6px; border-radius: 99px; background: var(--ph-accent); color: #fff; }
  .bar { height: 6px; border-radius: 99px; background: var(--ph-border); margin-top: 8px; overflow: hidden; }
  .bar > div { height: 100%; background: var(--ph-accent); border-radius: 99px; }
  .fil { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
  .chip { display: flex; align-items: center; gap: 4px; font-size: 12px; }
  .dot { width: 14px; height: 14px; border-radius: 50%; border: 1px solid var(--ph-border); display: inline-block; }
  .actions { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 8px; }
  button { font-size: 12px; padding: 3px 10px; border-radius: 8px; border: 1px solid var(--ph-border); background: transparent; color: inherit; cursor: pointer;
           transition-property: background-color, transform; transition-duration: 150ms; transition-timing-function: ease-out; }
  button:hover { background: rgba(128, 128, 128, .15); }
  button:active { transform: scale(.96); }
  @media (prefers-reduced-motion: reduce) { button { transition: none; } button:active { transform: none; } }
  button.danger { color: var(--ph-danger); }
  .sec { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--ph-border); }
  .sec.err { border-left: 0; padding-left: 0; color: var(--ph-danger); }
  .sec input[type=number] { width: 52px; font-size: 12px; }
  .sec input[type=range] { width: 120px; vertical-align: middle; }
  .sec select { font-size: 12px; max-width: 150px; }
  .line { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; margin: 4px 0; }
  .lbl { min-width: 62px; font-size: 12px; }
  img.cam { width: 100%; border-radius: 8px; margin-top: 8px; background: #000; min-height: 40px; }
  img.thumb { width: 64px; height: 48px; object-fit: cover; border-radius: 8px; margin-right: 4px; }
  .compact .detail { display: none; }
  #status { color: var(--ph-muted); font-size: 12px; }
  #status.err { color: inherit; }
</style>
<div class="top">
  <h3>Printer Hub</h3>
  <span>
    <label><input type="checkbox" id="sort"> problems first</label>
    <label><input type="checkbox" id="compact"> compact</label>
    <select id="every" title="Refresh">
      <option value="3000">3 s</option><option value="5000" selected>5 s</option><option value="10000">10 s</option>
    </select>
  </span>
</div>
<div id="list"></div>
<p id="status">Connecting to the Printer Hub app…</p>
<script>
(function () {
  var HUB = "http://127.0.0.1:7126";
  var open = {};        // slug -> {controls, history, spools, rules, cam}
  var extra = {};       // slug -> {history, spools, rules} payloads
  var last = null;      // last printers payload
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function esc(v) { var s = document.createElement("span"); s.textContent = v == null ? "" : String(v); return s.innerHTML; }
  // A JS string literal safe inside a double-quoted HTML attribute.
  function q(v) { return "'" + String(v).replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/"/g, "&quot;").replace(/</g, "&lt;") + "'"; }
  function dur(s) { if (!s) return ""; var h = Math.floor(s / 3600), m = Math.round(s % 3600 / 60); return h ? h + " h " + m + " min" : m + " min"; }
  function clock(s) { var d = new Date(Date.now() + s * 1000); return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); }
  function t(cur, tgt) { return Math.round(cur) + "°" + (tgt ? " → " + Math.round(tgt) + "°" : ""); }
  function send(o) { orca.postMessage(o); }
  window.ph = {
    act: function (slug, action, params, confirmText) {
      if (confirmText && !confirm(confirmText)) return;
      send({ command: "action", printer: slug, action: action, params: params || {} });
    },
    val: function (id) { var e = document.getElementById(id); return e ? e.value : ""; },
    toggle: function (slug, what) {
      var o = open[slug] = open[slug] || {};
      o[what] = !o[what];
      if (o[what] && what !== "controls" && what !== "cam") send({ command: what, printer: slug });
      render(true);
    },
    copy: function (text) {
      try { navigator.clipboard.writeText(text); document.getElementById("status").textContent = "Copied " + text; }
      catch (e) { prompt("Copy:", text); }
    }
  };

  function controls(p) {
    var s = esc(p.slug), slug = q(p.slug), out = '<div class="sec">';
    out += '<div class="line"><span class="lbl">Nozzle</span><input type="number" id="nz-' + s + '" value="' + Math.round(p.hotendTarget || 0) + '">' +
      '<button onclick="ph.act(' + slug + ',\'nozzle\',{value:ph.val(\'nz-' + s + '\')})">Set</button></div>';
    out += '<div class="line"><span class="lbl">Bed</span><input type="number" id="bd-' + s + '" value="' + Math.round(p.bedTarget || 0) + '">' +
      '<button onclick="ph.act(' + slug + ',\'bed\',{value:ph.val(\'bd-' + s + '\')})">Set</button></div>';
    if (p.chamberTarget != null)
      out += '<div class="line"><span class="lbl">Chamber</span><input type="number" id="ch-' + s + '" value="' + Math.round(p.chamberTarget || 0) + '">' +
        '<button onclick="ph.act(' + slug + ',\'chamber\',{value:ph.val(\'ch-' + s + '\')})">Set</button></div>';
    var o = last.orca || {};
    out += '<div class="line"><span class="lbl">Preheat</span>' +
      (o.nozzle ? '<button onclick="ph.act(' + slug + ',\'preheat\',{nozzle:' + o.nozzle + ',bed:' + o.bed + '})">Orca filament (' + o.nozzle + '/' + o.bed + ')</button>' : '') +
      '<button onclick="ph.act(' + slug + ',\'preheat\',{nozzle:210,bed:60})">PLA</button>' +
      '<button onclick="ph.act(' + slug + ',\'preheat\',{nozzle:240,bed:75})">PETG</button>' +
      '<button onclick="ph.act(' + slug + ',\'preheat\',{nozzle:260,bed:100,chamber:50})">ABS</button>' +
      '<button onclick="ph.act(' + slug + ',\'cooldown\')">Cool down</button></div>';
    out += '<div class="line"><span class="lbl">Motion</span>' +
      '<button onclick="ph.act(' + slug + ',\'home\')">Home</button>' +
      '<button onclick="ph.act(' + slug + ',\'motors_off\')">Motors off</button>' +
      '<button class="danger" onclick="ph.act(' + slug + ',\'estop\',{},' + q("Emergency stop " + p.name + "?") + ')">E-stop</button></div>';
    (p.fans || []).forEach(function (f) {
      out += '<div class="line"><span class="lbl">' + esc(f.label) + '</span><input type="range" min="0" max="100" value="' + Math.round(f.value * 100) +
        '" onchange="ph.act(' + slug + ',\'fan\',{object:' + q(f.object) + ',value:this.value/100})"><span class="muted">' + Math.round(f.value * 100) + '%</span></div>';
    });
    out += '<div class="line"><span class="lbl">Speed</span><input type="range" min="50" max="200" value="' + p.speed + '" onchange="ph.act(' + slug + ',\'speed\',{value:this.value})"><span class="muted">' + p.speed + '%</span></div>';
    out += '<div class="line"><span class="lbl">Flow</span><input type="range" min="75" max="125" value="' + p.flow + '" onchange="ph.act(' + slug + ',\'flow\',{value:this.value})"><span class="muted">' + p.flow + '%</span></div>';
    out += '<div class="line"><span class="lbl">Z offset</span>' +
      [-0.05, -0.01, 0.01, 0.05].map(function (d) { return '<button onclick="ph.act(' + slug + ',\'zoffset\',{value:' + d + '})">' + (d > 0 ? "+" : "") + d + '</button>'; }).join("") +
      '<span class="muted">' + (p.zOffset || 0).toFixed(3) + ' mm</span></div>';
    if (p.canPauseAtLayer)
      out += '<div class="line"><span class="lbl">Pause at</span><input type="number" id="pl-' + s + '" value="' + ((p.layer || 0) + 1) + '">' +
        '<button onclick="ph.act(' + slug + ',\'pause_at_layer\',{value:ph.val(\'pl-' + s + '\')})">Set</button>' +
        '<button onclick="ph.act(' + slug + ',\'pause_at_layer\',{value:0})">Off</button></div>';
    if ((p.macros || []).length)
      out += '<div class="line"><span class="lbl">Macro</span><select id="mc-' + s + '">' + p.macros.map(function (m) { return '<option>' + esc(m) + '</option>'; }).join("") +
        '</select><button onclick="ph.act(' + slug + ',\'macro\',{name:ph.val(\'mc-' + s + '\')},\'Run \'+ph.val(\'mc-' + s + '\')+\'?\')">Run</button></div>';
    if ((p.objects || []).length && (p.state === "printing" || p.state === "paused"))
      out += '<div class="line"><span class="lbl">Objects</span><select id="ob-' + s + '">' + p.objects.map(function (m) { return '<option>' + esc(m) + '</option>'; }).join("") +
        '</select><button class="danger" onclick="ph.act(' + slug + ',\'exclude\',{name:ph.val(\'ob-' + s + '\')},\'Stop printing \'+ph.val(\'ob-' + s + '\')+\'?\')">Exclude</button></div>';
    if (p.heater) {
      out += '<div class="line"><span class="lbl">Heater</span>' +
        (p.heater.mode === "drying" ? '<button onclick="ph.act(' + slug + ',\'dry_stop\')">Stop drying</button>'
          : '<input type="number" id="dt-' + s + '" value="55">°<input type="number" id="dh-' + s + '" value="6">h' +
            '<button onclick="ph.act(' + slug + ',\'dry\',{temp:ph.val(\'dt-' + s + '\'),hours:ph.val(\'dh-' + s + '\')})">Dry</button>') +
        '<button onclick="ph.act(' + slug + ',\'heater_filter\',{value:1})">Filter on</button>' +
        '<button onclick="ph.act(' + slug + ',\'heater_filter\',{value:0})">Filter off</button>' +
        (p.heater.fault ? '<button onclick="ph.act(' + slug + ',\'heater_reset\')">Clear fault</button>' : '') + '</div>';
    }
    if (p.meshRange != null) out += '<div class="muted">Bed mesh range ' + p.meshRange.toFixed(3) + ' mm</div>';
    return out + '</div>';
  }

  function history(p) {
    var h = (extra[p.slug] || {}).history;
    if (!h) return '<div class="sec muted">Loading history…</div>';
    if (h.error) return '<div class="sec err">' + esc(h.error) + '</div>';
    var done = h.filter(function (j) { return j.status === "completed"; }).length, fin = h.filter(function (j) { return j.status !== "in_progress"; }).length;
    var busy = p.state === "printing" || p.state === "paused";
    var out = '<div class="sec"><div class="muted">Last ' + h.length + ' prints · ' + (fin ? Math.round(done * 100 / fin) : 0) + '% succeeded</div>';
    h.forEach(function (j) {
      var icon = { completed: "✓", cancelled: "✕", in_progress: "…" }[j.status] || "!";
      var short = j.file.split("/").pop();
      out += '<div class="line">' + icon + ' <span>' + esc(short) + '</span> <span class="muted">' + dur(j.duration) + ' · ' +
        new Date(j.start).toLocaleDateString() + '</span>' +
        (j.exists && !busy ? '<button onclick="ph.act(' + q(p.slug) + ',\'reprint\',{file:' + q(j.file) + '},' + q("Print " + short + " again?") + ')">Reprint</button>' : '') + '</div>';
      if ((j.pictures || []).length)
        out += '<div>' + j.pictures.map(function (n) { return '<img class="thumb" src="' + HUB + '/hub/picture?printer=' + encodeURIComponent(p.slug) + '&name=' + encodeURIComponent(n) + '">'; }).join("") + '</div>';
    });
    return out + '</div>';
  }

  function spools(p) {
    var d = (extra[p.slug] || {}).spools;
    if (!d) return '<div class="sec muted">Loading spools…</div>';
    if (d.error) return '<div class="sec err">' + esc(d.error) + '</div>';
    if (!d.enabled) return '<div class="sec muted">Spoolman isn\'t set up on this printer.</div>';
    var lanes = (p.filaments || []).filter(function (f) { return f.label && /^T\d/.test(f.label); });
    var s = esc(p.slug), out = '<div class="sec">';
    d.spools.forEach(function (sp) {
      out += '<div class="line"><span class="dot" style="background:' + esc(sp.color || "transparent") + '"></span>' + esc(sp.name || ("Spool " + sp.id)) +
        ' <span class="' + (sp.remaining != null && sp.remaining < 100 ? "warn" : "muted") + '">' + esc(sp.material) + (sp.remaining != null ? ' · ' + Math.round(sp.remaining) + ' g' : '') +
        (sp.remaining != null && sp.remaining < 100 ? ' · low' : '') + (sp.id === d.active ? ' · active' : '') + '</span>' +
        (lanes.length ? '<select id="sl-' + s + '-' + sp.id + '">' + lanes.map(function (l) { return '<option value="E' + esc(l.label.slice(1)) + '">' + esc(l.label) + '</option>'; }).join("") +
          '</select><button onclick="ph.act(' + q(p.slug) + ',\'link_spool\',{lane:ph.val(\'sl-' + s + '-' + sp.id + '\'),spool:' + sp.id + '})">Load</button>' : '') + '</div>';
    });
    if (!d.spools.length) out += '<div class="muted">No spools yet.</div>';
    var loaded = lanes.filter(function (l) { return l.material; });
    if (loaded.length)
      out += '<div class="line"><span class="lbl">Add spool</span><select id="al-' + s + '">' + loaded.map(function (l) {
        return '<option value="E' + esc(l.label.slice(1)) + '">' + esc(l.label + " " + l.material) + '</option>'; }).join("") +
        '</select><input type="number" id="ag-' + s + '" value="1000">g<button onclick="ph.act(' + q(p.slug) + ',\'add_spool\',{lane:ph.val(\'al-' + s + '\'),grams:ph.val(\'ag-' + s + '\')})">Add</button></div>';
    return out + '</div>';
  }

  function rules(p) {
    var r = (extra[p.slug] || {}).rules;
    if (!r) return '<div class="sec muted">Loading rules…</div>';
    if (r.error) return '<div class="sec err">' + esc(r.error) + '</div>';
    if (!r.length) return '<div class="sec muted">No rules. Add them in the Printer Hub app (Tools → Rules).</div>';
    return '<div class="sec">' + r.map(function (x, i) {
      return '<div class="line"><input type="checkbox" ' + (x.off ? "" : "checked") + ' onchange="ph.act(' + q(p.slug) + ',\'rule_toggle\',{index:' + i + '})"> ' +
        esc((x.on === "time" ? "Daily " + x.at : x.on + (x.at ? " " + x.at : "")) + " → " + (x.label || x["do"])) + '</div>';
    }).join("") + '</div>';
  }

  function card(p) {
    var active = p.state === "printing" || p.state === "paused";
    var look = !p.online ? " is-off" : p.state === "error" || (p.heater && p.heater.fault) ? " is-err" : p.state === "paused" ? " is-paused" : "";
    var o = open[p.slug] || {}, slug = q(p.slug), orca = last.orca || {};
    var inOrca = p.proxy && orca.port && p.proxy.split(":")[1] === String(orca.port);
    var fil = (p.filaments || []).map(function (f) {
      return '<span class="chip"><span class="dot" style="background:' + esc(f.color || "transparent") + '"></span>' + esc(f.label) + " " + esc(f.material || "empty") + '</span>';
    }).join("");
    var mismatch = [];
    if (inOrca)
      (orca.materials || []).forEach(function (m, i) {
        var f = (p.filaments || []).filter(function (x) { return x.tool === i; })[0];
        if (f && f.material && m && f.material.toUpperCase() !== m.toUpperCase()) mismatch.push("Orca slot " + (i + 1) + " is " + m + ", " + f.label + " has " + f.material);
      });
    var h = '<div class="p' + look + '"><div class="row"><span class="name">' + esc(p.name) +
      (inOrca ? ' <span class="badge">in Orca</span>' : '') + '</span><span>' +
      (p.away ? '<span class="muted">away' + (p.delayMs ? " " + p.delayMs + " ms" : "") + '</span> ' : '') +
      '<span class="pill">' + (p.online ? esc(p.state) : "offline") + '</span></span></div>';
    h += '<div class="muted">Nozzle ' + t(p.hotend, p.hotendTarget) + ' · Bed ' + t(p.bed, p.bedTarget) +
      (p.chamber != null ? ' · Chamber ' + t(p.chamber, p.chamberTarget) : '') + '</div>';
    if (p.heater) h += '<div class="' + (p.heater.fault ? "err" : "muted") + ' detail">Heater: ' + (p.heater.fault ? "fault " + esc(p.heater.faultReason || "") : esc(p.heater.mode || "off")) + '</div>';
    if (active) h += '<div class="muted">' + esc((p.file || "").split("/").pop()) + '</div><div class="muted">' +
      (p.layer ? "Layer " + p.layer + (p.layers ? "/" + p.layers : "") + " · " : "") + Math.round(p.progress * 100) + "%" +
      (p.eta ? " · " + dur(p.eta) + " left, done " + clock(p.eta) : "") + '</div><div class="bar"><div style="width:' + Math.round(p.progress * 100) + '%"></div></div>';
    if (p.message && p.state === "paused") h += '<div class="warn">' + esc(p.message) + '</div>';
    if (o.cam) h += '<img class="cam" src="' + HUB + '/hub/snapshot?printer=' + encodeURIComponent(p.slug) + '&t=' + Date.now() + '" alt="No camera picture">';
    if (fil) h += '<div class="fil detail">' + fil + '</div>';
    mismatch.forEach(function (m) { h += '<div class="warn detail">⚠ ' + esc(m) + '</div>'; });
    if (p.proxy) h += '<div class="muted detail">Orca connection: 127.0.0.1, port ' + esc(p.proxy.split(":")[1]) +
      ' <button onclick="ph.copy(' + q(p.proxy.split(":")[1]) + ')">Copy port</button></div>';
    h += '<div class="actions">' +
      '<button onclick="ph.toggle(' + slug + ',\'cam\')">Camera</button>' +
      (p.light != null ? '<button onclick="ph.act(' + slug + ',\'light\')">Light ' + (p.light ? "off" : "on") + '</button>' : '') +
      (p.state === "printing" ? '<button onclick="ph.act(' + slug + ',\'pause\')">Pause</button>' : '') +
      (p.state === "paused" ? '<button onclick="ph.act(' + slug + ',\'resume\')">Resume</button>' : '') +
      (active ? '<button class="danger" onclick="ph.act(' + slug + ',\'cancel\',{},' + q("Cancel the print on " + p.name + "?") + ')">Cancel</button>' : '') +
      '<button onclick="ph.toggle(' + slug + ',\'controls\')">Controls</button>' +
      '<button onclick="ph.toggle(' + slug + ',\'history\')">History</button>' +
      '<button onclick="ph.toggle(' + slug + ',\'spools\')">Spools</button>' +
      '<button onclick="ph.toggle(' + slug + ',\'rules\')">Rules</button></div>';
    if (o.controls) h += controls(p);
    if (o.history) h += history(p);
    if (o.spools) h += spools(p);
    if (o.rules) h += rules(p);
    return h + '</div>';
  }

  function render(force) {
    if (!last) return;
    var list = document.getElementById("list");
    // Don't redraw under the user's fingers (typing, a slider, an open list).
    var a = document.activeElement;
    if (!force && a && (a.tagName === "INPUT" || a.tagName === "SELECT") && list.contains(a)) return;
    var ps = last.printers.slice();
    if (document.getElementById("sort").checked)
      ps.sort(function (x, y) { function r(p) { return !p.online || p.state === "error" || p.state === "paused" ? 0 : p.state === "printing" ? 1 : 2; } return r(x) - r(y); });
    list.className = document.getElementById("compact").checked ? "compact" : "";
    list.innerHTML = ps.map(card).join("");
  }

  orca.onMessage(function (m) {
    var st = document.getElementById("status");
    if (!m) return;
    if (m.command === "note") { st.textContent = m.text; return; }
    if (m.command === "extra") { extra[m.printer] = extra[m.printer] || {}; extra[m.printer][m.kind] = m.data; render(true); return; }
    if (m.command !== "printers") return;
    if (m.error) { document.getElementById("list").innerHTML = ""; st.textContent = m.error; st.className = "err"; return; }
    st.className = "";
    last = m; render(false);
    st.textContent = "Updated " + new Date().toLocaleTimeString();
  });

  ["sort", "compact"].forEach(function (id) {
    var e = document.getElementById(id); e.checked = store("ph." + id) === "1";
    e.addEventListener("change", function () { store("ph." + id, e.checked ? "1" : "0"); render(true); });
  });
  var every = document.getElementById("every");
  every.value = store("ph.every") || "5000";
  var timer = null;
  function tick() { send({ command: "refresh" }); }
  function schedule() { if (timer) clearInterval(timer); timer = setInterval(tick, parseInt(every.value, 10)); }
  every.addEventListener("change", function () { store("ph.every", every.value); schedule(); });
  tick(); schedule();
})();
</script>
"""


def _get(path):
    with urllib.request.urlopen(HUB + path, timeout=5) as r:
        return json.loads(r.read().decode("utf-8"))


def _first(value):
    if isinstance(value, (list, tuple)):
        return value[0] if value else None
    return value


def orca_context():
    """What Orca has selected now: the printer's connection port, the
    filament slots' materials and the first filament's temperatures."""
    out = {}
    try:
        bundle = orca.host.preset_bundle()
        printer = bundle.printers.get_edited_preset()
        out["port"] = str(printer.config_value("printhost_port") or "")
        names = list(bundle.current_filament_preset_names())
        mats = []
        for n in names:
            p = bundle.filaments.find_preset(n)
            mats.append(str(_first(p.config_value("filament_type")) or "") if p is not None else "")
        out["materials"] = mats
        if names:
            p = bundle.filaments.find_preset(names[0])
            if p is not None:
                nz = _first(p.config_value("nozzle_temperature"))
                bd = _first(p.config_value("hot_plate_temp")) or _first(p.config_value("textured_plate_temp"))
                if nz:
                    out["nozzle"], out["bed"] = int(float(nz)), int(float(bd or 60))
    except Exception:
        pass
    return out


def do_action(slug, action, params):
    query = {"printer": slug, "do": action}
    query.update({k: str(v) for k, v in (params or {}).items()})
    req = urllib.request.Request(HUB + "/hub/action?" + urllib.parse.urlencode(query), data=b"",
                                 method="POST", headers={"X-Printer-Hub": "1"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
    except urllib.error.HTTPError as e:
        try:
            reason = json.loads(e.read().decode("utf-8")).get("error", e.reason)
        except Exception:
            reason = e.reason
        raise RuntimeError(reason)


_OPEN_ON = {"NewProject", "ProjectOpened", "PresetSelected"}


class PrinterHubPanel(orca.script.ScriptPluginCapabilityBase):
    panel = None
    started = False      # opened once at Orca start; after that only when asked
    seen = None          # slug -> (state, chamber reached), for alerts

    def get_name(self):
        return "Printer Hub"

    def _open(self):
        if self.panel is not None and self.panel.is_open():
            self.panel.show()
            return
        self.panel = orca.host.ui.create_dock_panel(
            html=PAGE, title="Printer Hub", width=340, height=640,
            on_message=self.on_message, on_close=self.on_close, dock="right")

    def execute(self):
        self._open()
        return orca.ExecutionResult.success("Printer Hub opened.")

    # Orca has no "app started" event; the first project/preset event comes
    # right after launch, so open then (once).
    def on_lifecycle_event(self, event, ctx):
        if self.started or getattr(event, "name", str(event)).split(".")[-1] not in _OPEN_ON:
            return
        self.started = True
        try:
            self._open()
            self._notify("Printer Hub is open on the right.")
        except Exception:
            # Couldn't dock it yet: ask instead, one click away.
            self._notify("Printer Hub is ready.")

    def _notify(self, text, warn=False):
        try:
            ui = orca.host.ui
            level = ui.NotificationLevel.WarningNotificationLevel if warn else ui.NotificationLevel.RegularNotificationLevel
            ui.push_notification(level, text, hyper_text="Open Printer Hub", on_click=self._reopen)
        except Exception:
            pass

    def _alerts(self, printers):
        """Orca notifications on state changes (the first refresh only records)."""
        first = self.seen is None
        seen, self.seen = self.seen or {}, {}
        for p in printers:
            target = p.get("chamberTarget") or 0
            reached = target > 0 and (p.get("chamber") or 0) >= target - 1
            self.seen[p["slug"]] = (p.get("state"), reached)
            if first or p["slug"] not in seen:
                continue
            was, was_reached = seen[p["slug"]]
            now, name = p.get("state"), p["name"]
            if now != was:
                if now == "complete":
                    self._notify("%s: print finished" % name)
                elif now == "error":
                    self._notify("%s: print failed" % name, warn=True)
                elif now == "paused" and was == "printing":
                    self._notify("%s: paused · %s" % (name, p.get("message") or "check the printer"), warn=True)
            if reached and not was_reached:
                self._notify("%s: chamber at %d°C" % (name, target))

    def _refresh(self):
        try:
            printers = _get("/hub/printers")
        except Exception:
            self.panel.post({"command": "printers",
                             "error": "Printer Hub isn't answering. Open the Printer Hub app (Settings → Orca Slicer on)."})
            return
        self._alerts(printers)
        self.panel.post({"command": "printers", "printers": printers, "orca": orca_context(), "time": time.time()})

    def on_message(self, message):
        if self.panel is None:
            return
        message = message or {}
        command = message.get("command")
        slug = message.get("printer", "")
        if command == "refresh":
            self._refresh()
        elif command in ("history", "spools", "rules"):
            try:
                data = _get("/hub/%s?printer=%s" % (command, urllib.parse.quote(slug)))
            except Exception as e:
                data = {"error": "Could not load %s: %s" % (command, e)}
            self.panel.post({"command": "extra", "printer": slug, "kind": command, "data": data})
        elif command == "action":
            action = message.get("action", "")
            try:
                do_action(slug, action, message.get("params"))
                self.panel.post({"command": "note", "text": "Done: %s" % action.replace("_", " ")})
                self._refresh()
                if action in ("link_spool", "add_spool", "rule_toggle"):
                    self.on_message({"command": "rules" if action == "rule_toggle" else "spools", "printer": slug})
            except Exception as e:
                self.panel.post({"command": "note", "text": "Could not %s: %s" % (action.replace("_", " "), e)})

    def on_close(self):
        self.panel = None
        self._notify("Printer Hub panel closed.")

    def _reopen(self):
        self._open()
        return True  # close the notification


@orca.plugin
class PrinterHubPlugin(orca.base):
    def register_capabilities(self):
        orca.register_capability(PrinterHubPanel)
