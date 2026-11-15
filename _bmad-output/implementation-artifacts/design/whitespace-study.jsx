// Whitespace Study (2026-11-15): how the inspector should show text_field.dart while whitespace is ignored.
// The hunk is Ralph's real case: `return TextField(` wrapped in `Semantics(`, so 27 lines only moved right.
const { useState } = React;

const OLD0 = 71, NEW0 = 75; // the file's line numbers, as in Ralph's screenshot
const FIELDS = [
  "controller: controller,", "enabled: enabled,", "style: textStyle,", "keyboardType: keyboardType,",
  "textInputAction: textInputAction,", "textCapitalization: textCapitalization,", "autocorrect: autocorrect,",
  "enableSuggestions: enableSuggestions,", "focusNode: focusNode,", "obscureText: obscureText,",
  "decoration: InputDecoration(",
  "  label: label,", "  hintText: hintText,", "  helperText: helperText,", "  error: error,",
  "  prefixIcon: prefixIcon != null ? Opacity(opacity: opacity, child: prefixIcon) : null,",
  "  suffixIcon: _buildTrailing(),", "  counterText: counterText,", "  alignLabelWithHint: alignLabelWithHint,",
  "),",
  "onChanged: onChanged,", "onSubmitted: onSubmitted,", "autofocus: autofocus,", "maxLength: maxLength,",
  "minLines: minLines,", "maxLines: maxLines,", "buildCounter: buildCounter,",
];

// What `jj diff -w` aligns: context, the one real change, every field re-indented by two spaces, one added `),`.
const rows = () => {
  const r = [];
  const ctx = (o, n, s) => r.push({ k: " ", o: o + OLD0, n: n + NEW0, s });
  ctx(2, 2, "    final prefixIcon = this.prefixIcon;");
  ctx(3, 3, "    final opacity = enabled ? 1.0 : 0.38;");
  ctx(4, 4, "");
  r.push({ k: "-", o: 5 + OLD0, s: "    return TextField(" });
  r.push({ k: "+", n: 5 + NEW0, s: "    return Semantics(" });
  r.push({ k: "+", n: 6 + NEW0, s: "      identifier: identifier," });
  r.push({ k: "+", n: 7 + NEW0, s: "      child: TextField(" });
  FIELDS.forEach((f, i) => r.push({ k: " ", ws: true, o: 6 + i + OLD0, n: 8 + i + NEW0, s: "      " + f }));
  r.push({ k: "+", n: 35 + NEW0, s: "      )," });
  ctx(33, 36, "    );");
  ctx(34, 37, "  }");
  ctx(35, 38, "}");
  return r;
};

// Folded: like `jj diff -w`, the re-indented lines outside the context give way to a gap row.
const folded = (all) => {
  const out = [];
  const near = (i) => all.slice(Math.max(0, i - 3), i + 4).some((l) => l.k !== " ");
  for (let i = 0; i < all.length; i++) {
    if (near(i)) { out.push(all[i]); continue; }
    const last = out[out.length - 1];
    if (last && last.k === "gap") last.n++; else out.push({ k: "gap", n: 1 });
  }
  return out;
};

const Line = ({ l }) => {
  if (l.k === "gap") {
    return <div className="wss-gap"><span className="isd-nums"><span>⋯</span><span>⋯</span></span><span className="wss-gaptxt">{l.n} more lines with only whitespace changes</span></div>;
  }
  const cls = "isd-line k" + (l.k === "+" ? "a" : l.k === "-" ? "r" : "c");
  // A re-indented line: its new text with the two added spaces marked, as jj diff -w marks them.
  const text = l.ws
    ? <span className="isd-txt">{"    "}<span className="wss-wsmark">{"  "}</span>{l.s.slice(6)}</span>
    : <span className="isd-txt">{l.s}</span>;
  return (
    <div className={cls}>
      <span className="isd-nums"><span>{l.o ?? ""}</span><span>{l.n ?? ""}</span></span>
      <span className="isd-sig">{l.k === "+" ? "+" : l.k === "-" ? "−" : ""}</span>{text}
    </div>
  );
};

function Hunk({ title, note, startOpen }) {
  const [open, setOpen] = useState(startOpen);
  const all = rows();
  const shown = open ? all : folded(all);
  const ws = all.filter((l) => l.ws).length;
  return (
    <section className="wss-panel">
      <h2>{title}</h2>
      <p className="wss-note">{note}</p>
      <div className="isd-diff is-pinned">
        <div className="isd-dbar">
          <span className="isd-dpath"><span className="isd-dname">text_field.dart</span><span className="isd-ddir">packages/design/lib/src/widgets/</span></span>
          <span className="wss-mode">Ignore all whitespace · jj diff -w</span>
        </div>
        <div className="isd-dbody">
          <div className="isd-dcontent is-wide">
            <div className="isd-hunk">
              <div className="isd-hhd">
                <code>@@ −73,34 +77,37 @@</code>
                <button className="isd-wstag wss-pill" onClick={() => setOpen(!open)} title={open ? "Hide the marks again" : "Show every line that changed only in whitespace"}>
                  {ws} lines changed whitespace only · {open ? "Hide" : "Show"}
                </button>
                <span className="isd-stat"><span className="stat-add">+4</span><span className="stat-rem">−1</span></span>
              </div>
              {shown.map((l, i) => <Line key={i} l={l}/>)}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function App() {
  return (
    <div className="wss-win">
      <header className="wss-head">
        <b>Whitespace Study</b> — text_field.dart, the hunk that wraps <code>TextField</code> in <code>Semantics</code>.
        The lines come from <code>jj diff -w</code> itself; Zanshin no longer mixes in the exact diff's lines.
        Click the pill in a hunk header to switch.
      </header>
      <div className="wss-row">
        <Hunk startOpen={false} title="1 · Whitespace ignored (default)"
          note="Exactly what jj diff -w shows: one real change at the top, one added “),” at the bottom. The re-indented lines are context with their added indentation marked, as jj marks it; the ones far from a change collapse to a gap. The header says how many lines changed only in whitespace."/>
        <Hunk startOpen={true} title="2 · After “Show”"
          note="The gap opens: every line that changed only in whitespace is back where it belongs, with both numbers and the same marks. Nothing was deleted, the lines only moved right."/>
      </div>
      <footer className="wss-foot">
        A part that changed <i>only</i> whitespace (no line left under <code>jj diff -w</code>) keeps its folded row, with the same words:
        <div className="isd-foldrow wss-fold"><span className="isd-nums"><span/><span/></span><span className="isd-foldtxt">⋯ 7 lines changed whitespace only · Show</span></div>
      </footer>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
