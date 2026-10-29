"""Build the files of the Zanshin Design System artifact from the design system kept in this repository.

usage: python3 -I build_ds.py <design_system dir> <out dir> <design-system.json read from the artifact>

Writes <out>/project/... (everything but the index) and prints a report, the asset files the index does not
record yet (upload those first), and the publish map (JSON) for the Artifact tool's `files`.
"""
import datetime
import json
import os
import re
import shutil
import sys

SRC, OUT, INDEX = sys.argv[1], sys.argv[2], sys.argv[3]
PROJ = os.path.join(OUT, 'project')
NAMESPACE = 'ZanshinDesignSystem_a33847'
HERE = os.path.dirname(os.path.abspath(__file__))
report = []
published = {}  # served path -> source (relative to OUT) or {from, contentType}


def src(*p):
    return os.path.join(SRC, *p)


def read(rel):
    with open(src(rel), encoding='utf-8') as f:
        return f.read()


def write(rel, text):
    path = os.path.join(PROJ, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    published['project/' + rel] = 'project/' + rel


def copy(from_path, to_rel, content_type=None):
    path = os.path.join(PROJ, to_rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    shutil.copyfile(from_path, path)
    published['project/' + to_rel] = {'from': 'project/' + to_rel, 'contentType': content_type} if content_type else 'project/' + to_rel


# ---------------------------------------------------------------- CSS declarations per theme

COLOR_RE = re.compile(r'^(#[0-9a-fA-F]{3,8}|(rgba?|hsla?)\([0-9.,%\s]+\))$')
LEN_RE = re.compile(r'^(0|-?\d*\.?\d+(px|%|em|rem)?)$')
DECL_RE = re.compile(r'--([A-Za-z0-9-]+)\s*:\s*([^;]+?)\s*;\s*(/\*(.*?)\*/)?', re.S)
SECTION_RE = re.compile(r'/\*\s*-{2,}\s*(.*?)\s*-{2,}\s*\*/')


def blocks(css):
    """Yields (theme, [(name, value, note, section)]) for the :root/night and paper blocks only (deltas are skipped)."""
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', css):
        sel = [s.strip() for s in m.group(1).split('*/')[-1].split(',')]
        if any(s in (':root', '[data-theme="night"]') for s in sel):
            theme = 'night'
        elif any(s in ('[data-theme="paper"]', '[data-theme="light"]') for s in sel):
            theme = 'paper'
        else:
            continue
        body, section, decls, pos = m.group(2), '', [], 0
        for d in DECL_RE.finditer(body):
            for s in SECTION_RE.finditer(body, pos, d.start()):
                section = s.group(1)
            pos = d.end()
            note = re.sub(r'@kind \w+', '', (d.group(4) or '')).strip()
            decls.append((d.group(1), d.group(2).strip(), note, section))
        yield theme, decls


def usage_of(note, section, fallback):
    text = re.sub(r'\s+', ' ', note or section or fallback).strip()
    if text and text[-1] not in '.:)':
        text += '.'
    return text[0].upper() + text[1:] if text else text


# ---------------------------------------------------------------- tokens.json (a mirror for the editor; the CSS stays the truth)

colors, color_usage, order, dropped, shadow = {}, {}, [], [], {}
for f in ['tokens/colors.css', 'tokens/states.css']:
    for theme, decls in blocks(read(f)):
        for name, value, note, section in decls:
            if 'shadow' in name and 'var(' not in value:
                shadow.setdefault(name, {'name': name, 'value': {}, 'usage': usage_of(note, section, 'Shadow')})
                shadow[name]['value'][theme] = value
                continue
            alias = re.fullmatch(r'var\(--([A-Za-z0-9-]+)\)', value)
            if COLOR_RE.match(value):
                v = value.lower()
            elif alias:
                v = '{' + alias.group(1) + '}'
            else:
                if not LEN_RE.match(value) and 'gradient' not in value:
                    dropped.append(f'{name}={value[:60]} ({f})')
                continue
            if name not in colors:
                colors[name] = {}
                order.append(name)
            colors[name][theme] = v
            if note or name not in color_usage:
                color_usage[name] = usage_of(note, section, 'Zanshin colour token')
for name in list(order):
    for theme, v in list(colors[name].items()):
        if v.startswith('{') and v[1:-1] not in colors:
            del colors[name][theme]
    if not colors[name]:
        order.remove(name)
        dropped.append(f'{name} (alias of a non-colour)')
color_tokens = [{'name': n, 'value': colors[n]['night'] if set(colors[n]) == {'night'} else colors[n], 'usage': color_usage[n]} for n in order]

spacing, radius, zindex, seen = [], [], [], set(colors)
for f in ['tokens/spacing.css', 'tokens/effects.css']:
    for theme, decls in blocks(read(f)):
        for name, value, note, section in decls:
            if name.startswith('z-') and theme == 'night':
                zindex.append({'name': name, 'value': value, 'usage': usage_of(note, section, 'Layer')})
                continue
            if name.startswith(('fl-shadow', 'shadow-', 'ring-')):
                if 'var(' not in value:
                    shadow.setdefault(name, {'name': name, 'value': {}, 'usage': usage_of(note, section, 'Shadow')})
                    shadow[name]['value'][theme] = value
                continue
            if theme != 'night' or name in seen or not LEN_RE.match(value):
                continue
            seen.add(name)
            entry = {'name': name, 'value': value if value != '0' else '0px', 'usage': usage_of(note, section, 'Geometry')}
            (radius if name.startswith('radius-') else spacing).append(entry)

typo = read('tokens/typography.css')
families = {k: v.strip() for k, v in re.findall(r'--font-(sans|mono|kanji):([^;]+);', typo)}
tracking = {'inspector-title': '-0.012em', 'dialog-title': '-0.01em', 'caps': '0.1em'}
samples = {
    'inspector-title': 'feat(onboarding): swipe gestures', 'dialog-title': 'jj log Configurations',
    'panel-title': 'Changes', 'card-subject': 'exp: drop legacy ChangeNotifier wrappers',
    'body': 'No changes yet — whatever you edit in your editor lands here.', 'control': 'Squash into parent',
    'secondary': '4 files · +149 −140', 'meta': 'Ralph Stein · 3h', 'caps': 'GRAPH VIEW', 'id': 'ovknlmro',
    'command': 'jj rebase -s ovknlmro -o vruxwmqv', 'code': '+  void onEnd(DragEndDetails d) {',
}
groups = {'sans': [], 'mono': []}
for name, w, size, lh, fam in re.findall(r'--type-([a-z-]+):(\d+) ([\d.]+px)/([\d.]+) var\(--font-(\w+)\);', typo):
    style = {'name': name, 'fontSize': size, 'lineHeight': float(lh), 'fontWeight': int(w), 'sample': samples.get(name, name)}
    if name in tracking:
        style['letterSpacing'] = tracking[name]
    groups[fam].append(style)
for fname in sorted(os.listdir(src('assets/fonts'))):
    copy(src('assets/fonts', fname), 'fonts/' + fname)

tokens = {
    'name': 'Zanshin Design System', 'version': 1,
    'meta': {'source': 'code', 'repo': 'Zanshin', 'path': '_bmad-output/implementation-artifacts/design_system',
             'synced': datetime.date.today().isoformat()},
    'color': {'themes': [{'id': 'night', 'name': 'Night'}, {'id': 'paper', 'name': 'Paper'}], 'tokens': color_tokens},
    'type': {
        'fonts': [
            {'family': 'Inter', 'file': 'fonts/inter-latin.woff2', 'weight': '400 700'},
            {'family': 'JetBrains Mono', 'file': 'fonts/jetbrains-mono-latin.woff2', 'weight': '400 700'},
            {'family': 'Shippori Mincho', 'file': 'fonts/shippori-mincho-kanji-500.woff2', 'weight': '500'},
            {'family': 'Shippori Mincho', 'file': 'fonts/shippori-mincho-kanji-600.woff2', 'weight': '600'},
        ],
        'families': families,
        'groups': [
            {'name': 'UI — Inter', 'family': 'sans', 'styles': groups['sans']},
            {'name': 'Anything jj prints — JetBrains Mono', 'family': 'mono', 'styles': groups['mono']},
        ],
    },
    'spacing': {'tokens': spacing},
    'radius': {'tokens': radius},
    'shadow': {'tokens': list(shadow.values())},
    'zIndex': {'tokens': zindex},
}
write('tokens.json', json.dumps(tokens, ensure_ascii=False, indent=1))

# ---------------------------------------------------------------- bundle, the full stylesheet, types, component guidelines

bundle = read('_ds_bundle.js')
if '</script' in bundle.lower() or '<!--' in bundle:
    sys.exit('_ds_bundle.js holds a literal </script or <!-- — escape it first')
copy(src('_ds_bundle.js'), 'components/bundle.js')

css_parts = []
for rel in re.findall(r'@import "([^"]+)";', read('styles.css')):
    css = read(rel).replace('url("../assets/fonts/', 'url("../fonts/')
    css_parts.append(f'/* ---- {rel} ---- */\n{css}')
bundle_css = '\n'.join(css_parts)
if '</style' in bundle_css.lower():
    sys.exit('a stylesheet holds a literal </style')
write('components/bundle.css', bundle_css)

dts, comps = [], []
for group in sorted(os.listdir(src('components'))):
    gdir = src('components', group)
    if not os.path.isdir(gdir):
        continue
    for fname in sorted(os.listdir(gdir)):
        if fname.endswith('.d.ts'):
            dts.append(f'// ---- components/{group}/{fname}\n' + read(f'components/{group}/{fname}').replace('import * as React from "react";\n', ''))
            comps.append(fname[:-5])
        elif fname.endswith('.prompt.md'):
            copy(src('components', group, fname), f'components/{fname[:-10]}/README.md')
write('components/index.d.ts', 'import * as React from "react";\n\n' + '\n'.join(dts))
published['project/components/index.d.ts'] = {'from': 'project/components/index.d.ts', 'contentType': 'text/plain'}

# ---------------------------------------------------------------- showcase pages: the specimen cards, guideline cards and the desktop kit

index = json.load(open(INDEX, encoding='utf-8'))
blob = {name: '/_blob/' + rec['blob'] for g in index['assetGroups'].values() for name, rec in g.get('files', {}).items()}
manifest = json.load(open(src('_ds_manifest.json'), encoding='utf-8'))
taken = set(comps) | {c['name'] for c in manifest['components']}
FRAME_TAGS = [
    re.compile(r'<!-- @dsCard[^>]*-->\n?'),
    re.compile(r'<link rel="stylesheet" href="(\.\./)+styles\.css"\s*/?>\n?'),
    re.compile(r'<script src="https://unpkg\.com/react(-dom)?@[^"]+"[^>]*></script>\n?'),
    re.compile(r'<script src="(\.\./)+_ds_bundle\.js"></script>\n?'),
]


def strip(html):
    for rx in FRAME_TAGS:
        html = rx.sub('', html)
    return html


def asset_url(m):
    name = os.path.basename(m.group(2))
    if '/motion/' in m.group(2):
        return f'{m.group(1)}="../../assets/Motion/{name}"'
    if name in blob:
        return f'{m.group(1)}="{blob[name]}"'
    report.append(f'no upload for {m.group(2)}')
    return m.group(0)


def page_name(card, suffix):
    base = ''.join(w[:1].upper() + w[1:] for w in re.findall(r'[A-Za-z0-9]+', card['name']))
    name = base + suffix
    if name in taken:
        name = base + 'Showcase'
    assert name not in taken, name
    taken.add(name)
    return name


for card in manifest['cards']:
    path = card['path']
    html = strip(read(path))
    if path.startswith('components/'):
        name = page_name(card, 'Page')
    elif path.startswith('guidelines/'):
        html = html.replace('href="specimen.css"', 'href="../../guidelines/specimen.css"')
        html = re.sub(r'(src|href)="\.\./assets/([^"]+)"', asset_url, html)
        name = page_name(card, 'Guide')
    elif path == 'ui_kits/desktop/index.html':
        html = re.sub(r'(src|href)="(?!https?:|\.\./|#)([^"]+)"', r'\1="../../ui_kits/desktop/\2"', html)
        name = page_name(card, 'Page')
    else:
        report.append(f'card not placed: {path}')
        continue
    w, h = card['viewport'].split('x')
    sub = card['subtitle'].replace('"', "'").replace('<', '‹').replace('>', '›').replace('--', '–')
    grp = card['group'].replace('"', "'")
    write(f'components/{name}/preview.html', f'<!-- @dsCard group="{grp}" height={h} width={w} page subtitle="{sub}" -->\n' + html)
copy(src('guidelines/specimen.css'), 'guidelines/specimen.css')
for fname in sorted(os.listdir(src('ui_kits/desktop'))):
    if fname != 'index.html':
        copy(src('ui_kits/desktop', fname), 'ui_kits/desktop/' + fname, 'text/plain' if fname.endswith('.jsx') else None)
copy(os.path.join(HERE, 'cover.html'), 'components/Cover/preview.html')

# ---------------------------------------------------------------- brand book and asset groups

NOTE = f"""> **This system is kept in the Zanshin repository** (`_bmad-output/implementation-artifacts/design_system/`) and published from there by Claude Code (`.claude/skills/design-artifacts/`); this page is read-only. Change the repository, then republish. Everything below the rule is the system's own brand book. Where it names repository paths, read: `tokens/*.css` → `tokens.json` (values) and `components/bundle.css` (the complete stylesheet, every delta included) · `styles.css` → `components/bundle.css` · `components/<group>/<Comp>.prompt.md` → `components/<Comp>/README.md` · `assets/icons/ui/` → asset group Icons · `assets/*.svg`, `assets/app-icon/` → Logos · `assets/motion/` → `assets/Motion/`. Components mount from `window.{NAMESPACE}`; the specimen cards are the pages `components/*Page/` (and `SettingsShowcase`), the guideline cards `components/*Guide/`, the click-through desktop client `components/DesktopClientFloatingPage/` (running `ui_kits/desktop/`).
>
> **Only in `components/bundle.css`, not in `tokens.json`:** the two gradients (`--canvas`, `--fl-sheen`), the macOS accent families (`data-accent`), the increased-contrast, reduced-transparency and inactive-window deltas, motion, and every token built from `var()`, `calc()` or `color-mix()`. Not published: the Icon Composer bundle (`assets/app-icon/Zanshin-NamiIndigo.icon`). Usage notes on tokens paraphrase the stylesheet's comments.

---

"""
write('README.md', NOTE + read('readme.md'))
write('assets/Logos/README.md', '# Logos\n\nNami (three gold waves on indigo) is the mark; the wordmark is strokes, never a font. Never redraw them, never recolour beyond the three wordmark variants (gold on night, ink on paper, white on black). The splash is always dark (560 × 320); the wave ornament sits at 5% in the ground. The ensō is retired.\n')
write('assets/Icons/README.md', '# Icons\n\n59 glyphs on a 16-unit grid, one 1.5 stroke, round caps and joins, drawn in `currentColor`; solids only where meaning needs one. Size follows the control (`--icon-xs` 10 … `--icon-rail` 19), never decoration. In components use `Icon name="…"`. U-turn = operations (jj undo) · circular arrow = a change\'s inverse (jj revert).\n')
write('assets/Motion/README.md', '# Motion\n\nThe Nami loader as Lottie: one gaussian swell runs through the waves (1.3s + 0.55s pause). Three files as the repository ships them: `nami_loader.json`, `nami_loader_transparent.json`, `nami_loader_pulse.json`.\n')
for fname in sorted(os.listdir(src('assets/motion'))):
    copy(src('assets/motion', fname), 'assets/Motion/' + fname)

# uploads: every logo and icon must have a record in the index
recorded = {name for g in index['assetGroups'].values() for name in g.get('files', {})}
wanted = [('Logos', p) for p in ['zanshin-wordmark-gold.svg', 'zanshin-wordmark-ink.svg', 'zanshin-wordmark-white.svg',
                                 'app-icon/zanshin-icon-nami-indigo.svg', 'zanshin-waves.svg', 'zanshin-wave-ornament.svg',
                                 'zanshin-splash.svg', 'zanshin-splash-bg.svg']]
wanted += [('Icons', 'icons/ui/' + f) for f in sorted(os.listdir(src('assets/icons/ui')))]
missing = [{'group': g, 'name': os.path.basename(p), 'path': src('assets', p), 'size': os.path.getsize(src('assets', p))}
           for g, p in wanted if os.path.basename(p) not in recorded]

print('colors', len(color_tokens), 'spacing', len(spacing), 'radius', len(radius), 'shadow', len(shadow), 'z', len(zindex),
      'type styles', sum(len(g) for g in groups.values()))
for d in dropped:
    print('dropped:', d)
for r in report:
    print(r)
print('UPLOAD FIRST (not in the index):', json.dumps(missing))
print('FILES')
print(json.dumps(published, ensure_ascii=False))
