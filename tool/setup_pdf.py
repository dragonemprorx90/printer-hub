#!/usr/bin/env python3
"""Builds docs/Printer-Hub-Setup.pdf from docs/SETUP.md (macOS: WebKit via
tool/html2pdf.swift). Handles the Markdown that SETUP.md uses: headings,
paragraphs, lists, tables, code, bold, inline code and links.
    python3 tool/setup_pdf.py"""
import html, re, subprocess, sys, tempfile, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = 'https://github.com/dragonemprorx90/printer-hub'
md = (ROOT / 'docs/SETUP.md').read_text()
version = re.search(r"^version: ([\d.]+)", (ROOT / 'pubspec.yaml').read_text(), re.M).group(1)

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    def link(m):
        text, url = m.group(1), m.group(2)
        if url.startswith('#'):
            return text                       # in-page link: plain text on paper
        if not url.startswith('http'):
            url = f'{REPO}/blob/main/docs/{url}'.replace('/docs/../', '/')
        return f'<a href="{url}">{text}</a>'
    return re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, t)

out, lines, i = [], md.splitlines(), 0
while i < len(lines):
    l = lines[i]
    if l.strip().startswith('```'):
        indent = len(l) - len(l.lstrip()); i += 1; code = []
        while not lines[i].strip().startswith('```'):
            code.append(lines[i][indent:]); i += 1
        out.append('<pre>' + html.escape('\n'.join(code)) + '</pre>'); i += 1; continue
    if m := re.match(r'(#{1,3}) (.*)', l):
        n = len(m.group(1)); out.append(f'<h{n}>{inline(m.group(2))}</h{n}>'); i += 1; continue
    if l.startswith('|'):
        rows = []
        while i < len(lines) and lines[i].startswith('|'):
            if not re.match(r'^\|[\s|:-]+\|$', lines[i]):
                rows.append([c.strip() for c in lines[i].strip('|').split('|')])
            i += 1
        head, *body = rows
        out.append('<table><tr>' + ''.join(f'<th>{inline(c)}</th>' for c in head) + '</tr>' +
                   ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in body) + '</table>')
        continue
    if m := re.match(r'(\s*)(- |\d+\. )(.*)', l):
        tag = 'ol' if m.group(2)[0].isdigit() else 'ul'; items = []
        while i < len(lines) and (m := re.match(r'(\s*)(- |\d+\. )(.*)', lines[i])):
            item = [m.group(3)]; i += 1
            while i < len(lines) and lines[i].startswith('   ') and not lines[i].strip().startswith('```'):
                item.append(lines[i].strip()); i += 1
            if i < len(lines) and lines[i].strip().startswith('```'):   # code block inside an item
                indent = len(lines[i]) - len(lines[i].lstrip()); i += 1; code = []
                while not lines[i].strip().startswith('```'):
                    code.append(lines[i][indent:]); i += 1
                i += 1
                items.append(inline(' '.join(item)) + '<pre>' + html.escape('\n'.join(code)) + '</pre>')
            else:
                items.append(inline(' '.join(item)))
        out.append(f'<{tag}>' + ''.join(f'<li>{x}</li>' for x in items) + f'</{tag}>'); continue
    if l.strip():
        para = [l]; i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r'(#|\||```|\s*- |\s*\d+\. )', lines[i]):
            para.append(lines[i]); i += 1
        out.append('<p>' + inline(' '.join(para)) + '</p>'); continue
    i += 1

# Keep each heading on the same page as the block after it.
blocks = [b for b in out if b != '<h1>Setting up Printer Hub</h1>']
merged, k = [], 0
while k < len(blocks):
    if re.match(r'<h[23]>', blocks[k]) and k + 1 < len(blocks):
        nxt = blocks[k + 1]
        if re.match(r'<h3>', nxt) and k + 2 < len(blocks):   # h2 directly followed by h3
            merged.append(f'<div class="keep">{blocks[k]}{nxt}{blocks[k + 2]}</div>'); k += 3; continue
        merged.append(f'<div class="keep">{blocks[k]}{nxt}</div>'); k += 2; continue
    merged.append(blocks[k]); k += 1
body = '\n'.join(merged)
css = """
@page { size: A4; margin: 0; }
body { font: 10.5pt/1.5 -apple-system, 'Helvetica Neue', sans-serif; color: #111722; margin: 0 48px;
       -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.keep { break-inside: avoid; page-break-inside: avoid; }
.cover { border-bottom: 2px solid #0f9d74; padding: 8px 0 18px; margin-bottom: 18px; }
.cover .kicker { color: #0f9d74; font-weight: 700; letter-spacing: .12em; font-size: 8.5pt; text-transform: uppercase; }
.cover h1 { font-size: 26pt; margin: 4px 0 2px; letter-spacing: -.01em; }
.cover .sub { color: #5d677a; }
h2 { font-size: 15pt; margin: 26px 0 8px; padding-top: 6px; border-top: 1px solid #dce1e9; break-after: avoid; }
h3 { font-size: 11.5pt; margin: 18px 0 6px; break-after: avoid; }
p, li { orphans: 3; widows: 3; }
code { font: 9pt Menlo, monospace; background: #eef1f5; padding: 1px 4px; border-radius: 4px; }
pre { font: 8pt/1.5 Menlo, monospace; background: #0b0e13; color: #e9edf3; padding: 10px 12px;
      border-radius: 8px; white-space: pre-wrap; overflow-wrap: anywhere; break-inside: avoid; }
table { border-collapse: collapse; width: 100%; margin: 8px 0 12px; font-size: 9.5pt; break-inside: avoid; }
th { text-align: left; color: #5d677a; font-size: 8.5pt; text-transform: uppercase; letter-spacing: .06em; }
th, td { border-bottom: 1px solid #dce1e9; padding: 6px 8px 6px 0; vertical-align: top; }
a { color: #0b7a5a; text-decoration: none; }
ul, ol { padding-left: 20px; }
.foot { margin-top: 28px; color: #5d677a; font-size: 8.5pt; border-top: 1px solid #dce1e9; padding-top: 8px; }
"""
page = f"""<!doctype html><html><head><meta charset="utf-8"><title>Printer Hub setup</title>
<style>{css}</style></head><body>
<div class="cover"><div class="kicker">Printer Hub {version}</div><h1>Setup guide</h1>
<div class="sub">App, relay, home bridge (NAS · Raspberry Pi · PC) and OrcaSlicer</div></div>
{body}
<div class="foot">Latest version of this guide: {REPO}/blob/main/docs/SETUP.md</div>
</body></html>"""

with tempfile.TemporaryDirectory() as d:
    h = pathlib.Path(d) / 'setup.html'; h.write_text(page)
    pdf = ROOT / 'docs/Printer-Hub-Setup.pdf'
    r = subprocess.run(['swift', str(ROOT / 'tool/html2pdf.swift'), str(h), str(pdf)])
    sys.exit(r.returncode or print(f'wrote {pdf.relative_to(ROOT)}'))
