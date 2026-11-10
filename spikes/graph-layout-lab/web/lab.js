// The lab page: asks the local server for a layout and draws it. It decides nothing about the
// layout itself: cards and lines come finished from bin/lab_layout.dart.
'use strict';

const $ = (id) => document.getElementById(id);
const view = $('view');
const plane = $('plane');

// What the link in the address bar holds: data set, engine, mode, stacks, rules, zoom, scroll
// position and the selected card (c<node>) or line (l<edge>).
const state = { d: '', e: 'lab', m: 'free', s: '1', r: null, z: '1', x: '0', y: '0', sel: '' };
for (const [k, v] of new URLSearchParams(location.hash.slice(1))) {
  if (k in state) state[k] = v;
}

let scene = null;
let cardAt = new Map(); // node → card
let jump = { behind: 0, nearer: 0 };

function writeHash() {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(state)) {
    // An empty `r` means "every rule off" and must survive a reload; a missing one means "defaults".
    if (v !== null && (v !== '' || k === 'r')) q.set(k, v);
  }
  history.replaceState(null, '', '#' + q);
}

function toast(text) {
  $('toast').textContent = text;
  $('toast').classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => $('toast').classList.remove('show'), 1800);
}

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const cut = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

// A polyline with rounded corners.
function pathOf(p) {
  let d = `M${p[0]} ${p[1]}`;
  for (let q = 2; q + 3 < p.length; q += 2) {
    const [x0, y0, x1, y1, x2, y2] = [p[q - 2], p[q - 1], p[q], p[q + 1], p[q + 2], p[q + 3]];
    const r = Math.min(8, Math.hypot(x1 - x0, y1 - y0) / 2, Math.hypot(x2 - x1, y2 - y1) / 2);
    const a = Math.atan2(y1 - y0, x1 - x0);
    const b = Math.atan2(y2 - y1, x2 - x1);
    d += `L${x1 - r * Math.cos(a)} ${y1 - r * Math.sin(a)}Q${x1} ${y1} ${x1 + r * Math.cos(b)} ${y1 + r * Math.sin(b)}`;
  }
  return d + `L${p[p.length - 2]} ${p[p.length - 1]}`;
}

function draw() {
  const s = scene;
  const w = s.cardWidth;
  const h = s.cardHeight;
  const out = [];
  for (const day of s.days) {
    out.push(`<line class="day" x1="0" x2="${s.width}" y1="${day.y}" y2="${day.y}"/>`);
    out.push(`<text class="dayLabel" x="6" y="${day.y - 4}">${day.label}</text>`);
  }
  for (const line of s.lines) {
    const cls = 'ln' + (line.dashed ? ' dashed' : '') + (line.behind ? ' behind' : '');
    out.push(`<path class="${cls}" id="l${line.e}" d="${pathOf(line.pts)}"/>`);
  }
  for (const c of s.cards) {
    const cls = 'card' + (c.main ? ' main' : '') + (c.wc ? ' wc' : '') + (c.nearer ? ' nearer' : '');
    const title = c.stack ? cut(c.title, 26) : cut(c.title, 31);
    out.push(
      `<g class="${cls}" id="c${c.n}" transform="translate(${c.x} ${c.y})">` +
        `<title>${esc(c.title)}\n${esc(c.id)} · ${esc(c.sub)}</title>` +
        `<rect width="${w}" height="${h}" rx="9"/>` +
        (c.stack ? `<text class="n" x="12" y="25">${c.stack}×</text>` : '') +
        `<text class="t" x="${c.stack ? 40 : 12}" y="25">${esc(title)}</text>` +
        `<text class="s" x="12" y="46">${esc(c.id)} · ${esc(cut(c.sub, 28))}</text>` +
        (c.refs.length ? `<text class="ref" x="${w}" y="-5" text-anchor="end">${esc(cut(c.refs.join(', '), 40))}</text>` : '') +
        '</g>',
    );
  }
  plane.setAttribute('viewBox', `0 0 ${s.width} ${s.height}`);
  plane.innerHTML = out.join('');
  zoom();

  const m = s.metrics;
  $('metrics').innerHTML =
    `<span>${m.columns} Spalten</span><span>${m.crossings} Kreuzungen (${m.siblings} an einer Karte)</span>` +
    `<span>${m.overlaps} Linien übereinander</span><span>${m.bends} Knicke</span>` +
    `<span title="Spalten zwischen Eltern- und Kindkarte, über alle Linien">${m.sideways} Spalten Querweg</span>` +
    `<button id="jumpBehind" class="${m.behind ? 'flag' : ''}" title="Zur nächsten springen">${m.behind} Linien hinter Karten</button>` +
    `<button id="jumpNearer" class="${m.nearer ? 'flag' : ''}" title="Zur nächsten springen">${m.nearer} Karten mit freiem Platz näher an ihren Linien</button>`;
  $('jumpBehind').onclick = () => next('behind', s.lines, (l) => 'l' + l.e);
  $('jumpNearer').onclick = () => next('nearer', s.cards, (c) => 'c' + c.n);
  $('status').className = '';
  $('status').textContent = `${s.nodes} Commits · ${s.ms} ms`;

  $('rules').innerHTML = s.rules
    .map((r) => `<label><input type="checkbox" data-rule="${r.id}"${r.on ? ' checked' : ''}${s.engine === 'lab' ? '' : ' disabled'}> ${esc(r.label)}</label>`)
    .join('');
  for (const box of $('rules').querySelectorAll('input')) {
    box.onchange = () => {
      state.r = [...$('rules').querySelectorAll('input:checked')].map((b) => b.dataset.rule).join(',');
      load();
    };
  }
}

function zoom() {
  if (!scene) return;
  const z = Number(state.z);
  plane.setAttribute('width', scene.width * z);
  plane.setAttribute('height', scene.height * z);
  $('zoomReset').textContent = Math.round(z * 100) + ' %';
}

function setZoom(z) {
  const old = Number(state.z);
  const next = Math.min(2, Math.max(0.1, z));
  const mid = (view.scrollTop + view.clientHeight / 2) / old; // keep the middle of the window in place
  state.z = String(Math.round(next * 100) / 100);
  zoom();
  view.scrollTop = mid * next - view.clientHeight / 2;
  writeHash();
}

// Marks the selected card or line and what hangs on it. With `show`, scrolls it into the window.
function select(sel, show) {
  for (const el of plane.querySelectorAll('.sel')) el.classList.remove('sel');
  state.sel = sel;
  let box = null;
  if (sel.startsWith('c')) {
    const n = Number(sel.slice(1));
    const card = cardAt.get(n);
    if (!card) return null;
    $(sel).classList.add('sel');
    for (const l of scene.lines) {
      if (l.from === n || l.to === n) $('l' + l.e).classList.add('sel');
    }
    box = { x: card.x, y: card.y };
  } else if (sel.startsWith('l')) {
    const line = scene.lines.find((l) => 'l' + l.e === sel);
    if (!line) return null;
    $(sel).classList.add('sel');
    $('c' + line.from).classList.add('sel');
    $('c' + line.to).classList.add('sel');
    box = { x: line.pts[0], y: (line.pts[1] + line.pts[line.pts.length - 1]) / 2 };
  }
  if (box && show) {
    const z = Number(state.z);
    view.scrollTo(box.x * z - view.clientWidth / 3, box.y * z - view.clientHeight / 2);
  }
  writeHash();
  return box;
}

// Jumps to the next card or line that carries `flag`.
function next(flag, items, idOf) {
  const marked = items.filter((i) => i[flag]);
  if (!marked.length) return;
  select(idOf(marked[jump[flag]++ % marked.length]), true);
}

function describe(sel) {
  const id = (n) => `${cardAt.get(n).id} (#${n})`;
  if (sel.startsWith('c')) return `Karte ${id(Number(sel.slice(1)))}`;
  const line = scene.lines.find((l) => 'l' + l.e === sel);
  return `Linie ${id(line.from)} → ${id(line.to)}`;
}

async function copy(sel) {
  select(sel, false);
  const text = `${state.d} · ${state.e === 'lab' ? 'Labor' : 'App heute'} · ${state.m} · ${describe(sel)}\n${location.href}`;
  try {
    await navigator.clipboard.writeText(text);
    toast('Kopiert: ' + describe(sel));
  } catch {
    toast(describe(sel) + '\n(Zwischenablage nicht erreichbar, der Link steht in der Adresszeile)');
  }
}

// The line nearest to a click, within 6 px.
function lineAt(x, y) {
  let best = null;
  let least = 6;
  for (const l of scene.lines) {
    const p = l.pts;
    for (let q = 0; q + 3 < p.length; q += 2) {
      const dx = Math.max(Math.min(p[q], p[q + 2]) - x, 0, x - Math.max(p[q], p[q + 2]));
      const dy = Math.max(Math.min(p[q + 1], p[q + 3]) - y, 0, y - Math.max(p[q + 1], p[q + 3]));
      const dist = Math.hypot(dx, dy);
      if (dist < least) {
        least = dist;
        best = l;
      }
    }
  }
  return best;
}

plane.addEventListener('click', (ev) => {
  const card = ev.target.closest('.card');
  if (card) return copy(card.id);
  const z = Number(state.z);
  const r = plane.getBoundingClientRect();
  const line = lineAt((ev.clientX - r.left) / z, (ev.clientY - r.top) / z);
  if (line) copy('l' + line.e);
});

async function load() {
  writeHash();
  for (const group of ['engine', 'mode']) {
    for (const b of $(group).querySelectorAll('button')) {
      b.setAttribute('aria-pressed', String(b.dataset.v === state[group === 'engine' ? 'e' : 'm']));
    }
  }
  $('stacks').checked = state.s === '1';
  $('status').className = '';
  $('status').textContent = 'rechnet …';
  const q = new URLSearchParams({ data: state.d, engine: state.e, mode: state.m, stacks: state.s });
  if (state.r !== null) q.set('rules', state.r); // without it the server takes the rules' defaults
  const turn = (load.turn = (load.turn || 0) + 1);
  const res = await fetch('/api/layout?' + q);
  if (turn !== load.turn) return; // a newer request is on its way
  if (!res.ok) {
    $('status').className = 'error';
    $('status').textContent = (await res.text()).slice(0, 2000);
    return;
  }
  scene = await res.json();
  state.r = scene.rules.filter((r) => r.on).map((r) => r.id).join(',');
  writeHash();
  cardAt = new Map(scene.cards.map((c) => [c.n, c]));
  jump = { behind: 0, nearer: 0 };
  draw();
  view.scrollTo(Number(state.x), Number(state.y));
  if (state.sel && !select(state.sel, false)) state.sel = '';
}

for (const [group, key] of [['engine', 'e'], ['mode', 'm']]) {
  for (const b of $(group).querySelectorAll('button')) {
    b.onclick = () => {
      state[key] = b.dataset.v;
      load();
    };
  }
}
$('stacks').onchange = () => {
  state.s = $('stacks').checked ? '1' : '0';
  load();
};
$('data').onchange = () => {
  Object.assign(state, { d: $('data').value, x: '0', y: '0', sel: '' });
  load();
};
$('zoomOut').onclick = () => setZoom(Number(state.z) / 1.25);
$('zoomIn').onclick = () => setZoom(Number(state.z) * 1.25);
$('zoomReset').onclick = () => setZoom(1);

// A link pasted into an open lab tab changes only the hash: start again from it.
window.addEventListener('hashchange', () => location.reload());

let scrollTimer = 0;
view.addEventListener('scroll', () => {
  clearTimeout(scrollTimer);
  scrollTimer = setTimeout(() => {
    state.x = String(Math.round(view.scrollLeft));
    state.y = String(Math.round(view.scrollTop));
    writeHash();
  }, 150);
});

(async () => {
  const sets = await (await fetch('/api/datasets')).json();
  $('data').innerHTML = sets.map((s) => `<option>${esc(s)}</option>`).join('');
  if (!sets.length) {
    $('status').className = 'error';
    $('status').textContent = 'Keine Daten. Erzeuge sie mit tools/replica.sh (siehe README).';
    return;
  }
  if (!sets.includes(state.d)) state.d = sets[0];
  $('data').value = state.d;
  load();
})();
