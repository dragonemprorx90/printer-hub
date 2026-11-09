#!/usr/bin/env python3
"""Writes CHANGELOG.md from the in-app release notes (lib/whats_new.dart)
and the git tags. Run from the repo root after adding a kWhatsNew entry:
    python3 tool/changelog.py
Versions with no notes fall back to the tag's commit subject."""
import re, subprocess, datetime

src = open('lib/whats_new.dart').read()
body = src[src.index('const kWhatsNew'):]
body = body[:body.index('\n];')]
notes = {}
for m in re.finditer(r"\('([\d.]+)', \[(.*?)\n  \]\)", body, re.S):
    items = re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(2))
    notes[m.group(1)] = [i.replace("\\'", "'").replace('\\"', '"').replace('\\$', '$') for i in items]

def git(*a):
    return subprocess.run(['git', *a], capture_output=True, text=True).stdout.strip()

tags = {}
for line in git('tag', '--format=%(refname:short) %(creatordate:short) %(subject)').splitlines():
    t, d, subj = (line.split(' ', 2) + [''])[:3]
    if re.fullmatch(r'v[\d.]+', t):
        tags[t[1:]] = (d, subj)

key = lambda v: [int(x) for x in v.split('.')]
out = ['# Changelog', '',
       'Every release of Printer Hub (app, home bridge, relay and Orca plugin ship together).',
       'Downloads: [GitHub releases](https://github.com/dragonemprorx90/printer-hub/releases).', '']
tagged = sorted(tags, key=key)
for v in sorted(set(notes) | set(tags), key=key, reverse=True):
    date = tags.get(v, (str(datetime.date.today()), ''))[0]
    out.append(f'## {v} — {date}' if v in tags else f'## {v} — unreleased')
    out.append('')
    lines = notes.get(v)
    if not lines and v in tags:  # no in-app notes: the commits of that release
        i = tagged.index(v)
        rng = f'v{tagged[i - 1]}..v{v}' if i else f'v{v}'
        lines = []
        for subj in git('log', '--format=%s', rng).splitlines():
            subj = re.sub(r';? ?(version [\d.]+|\([\d.]+\))$', '', subj)
            subj = re.sub(r'^(Printer Hub |Version )?v?[\d.]+:? ?', '', subj).strip()
            if subj:
                lines.append(subj[:1].upper() + subj[1:])
    out += [f'- {l}' for l in (lines or ['First release'])] + ['']
open('CHANGELOG.md', 'w').write('\n'.join(out))
print(f'CHANGELOG.md: {len(set(notes) | set(tags))} versions')
