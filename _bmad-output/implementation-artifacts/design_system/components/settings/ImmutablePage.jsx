import React from "react";
import { SettingsPage } from "./SettingsPage.jsx";
import { SettingsGroup } from "./SettingsGroup.jsx";
import { SettingsRow } from "./SettingsRow.jsx";
import { Switch } from "../forms/Switch.jsx";
import { TextField } from "../forms/TextField.jsx";
import { Chip } from "../controls/Chip.jsx";
import { Button } from "../actions/Button.jsx";
import { Menu } from "../menus/Menu.jsx";
import { HatchSwatch } from "../graph/HatchSwatch.jsx";

// ImmutablePage — Settings › Project › Immutable commits: revset-aliases."immutable_heads()" as switches, chips and one field, with the TOML
// it writes and what it locks. jj won't rewrite the heads or anything below them (root() always); --ignore-immutable overrides.
// jj v0.46: builtin_immutable_heads() = trunk() | tags() | untracked_remote_bookmarks() | untracked_remote_tags().
// The page only edits the config; the app evaluates it (count, heads, unknown terms) and re-hatches the graph at once.
const ZS_IMM_BUILT = [
  ["trunk", "trunk()", "trunk"],
  ["tags", "tags()", "tags"],
  ["remoteBookmarks", "untracked_remote_bookmarks()", "untracked remote bookmarks"],
  ["remoteTags", "untracked_remote_tags()", "untracked remote tags"],
];
const ZS_IMM_DEFAULTS = { trunk: true, tags: true, remoteBookmarks: true, remoteTags: true, others: false, bookmarks: [], custom: "" };
const zsImmSym = (n) => (/^[\w./@+-]+$/.test(n) ? n : '"' + n.replace(/"/g, '\\"') + '"');
const zsTomlStr = (s) => (s.includes('"') ? "'" + s + "'" : '"' + s + '"');
function zsImmExpr(c) {
  const on = ZS_IMM_BUILT.filter(([k]) => c[k]);
  const parts = on.length === ZS_IMM_BUILT.length ? ["builtin_immutable_heads()"] : on.map((b) => b[1]);
  (c.bookmarks || []).forEach((b) => parts.push(zsImmSym(b)));
  if (c.others) parts.push("(trunk().. & ~mine())");
  const cu = (c.custom || "").trim();
  if (cu) parts.push(/[\s|&~]/.test(cu) && !/^\(.*\)$/.test(cu) ? "(" + cu + ")" : cu);
  return parts.length ? parts.join(" | ") : "none()";
}
function zsImmSummary(c) {
  const on = ZS_IMM_BUILT.filter(([k]) => c[k]);
  const list = [...(on.length === ZS_IMM_BUILT.length ? ["jj’s default (trunk, tags, remote bookmarks you don’t track)"] : on.map((b) => b[2])),
    ...(c.others ? ["other people’s changes"] : []), ...(c.bookmarks || []), ...((c.custom || "").trim() ? ["a custom revset"] : [])];
  if (!list.length) return "Only root()";
  const s = list.join(", ");
  return /^jj/.test(s) ? s : s[0].toUpperCase() + s.slice(1);
}

export function ImmutablePage({ config, onChange, trunkName = "main", project = "Project", onBack, tags = [], remoteBookmarks = [], remoteTags = [],
  bookmarks = [], count, heads = [], unknown = [], className = "" }) {
  const c = { ...ZS_IMM_DEFAULTS, ...(config || {}) };
  const set = (patch) => onChange && onChange({ ...c, ...patch });
  const [adding, setAdding] = React.useState(false);
  const addRef = React.useRef(null);
  React.useEffect(() => {
    if (!adding) return undefined;
    const down = (e) => { if (addRef.current && !addRef.current.contains(e.target)) setAdding(false); };
    document.addEventListener("pointerdown", down, true);
    return () => document.removeEventListener("pointerdown", down, true);
  }, [adding]);
  const list = (a) => (a.length ? a.join(", ") : "none here");
  // the add menu closes on a pick, Esc or a click outside; focus returns to the add chip
  const done = () => { setAdding(false); const b = addRef.current && addRef.current.querySelector("button"); if (b) b.focus(); };
  const choices = bookmarks.filter((b) => b !== trunkName && !c.bookmarks.includes(b));
  const sw = (k, label) => <Switch label={label} checked={!!c[k]} onChange={(v) => set({ [k]: v })} />;
  const expr = zsImmExpr(c);
  return (
    <SettingsPage className={("zs-imm " + className).trim()} back={project} onBack={onBack} title="Immutable commits"
      intro="jj won’t rewrite these changes or anything below them: no edit, describe, squash, rebase or abandon. New change on top and Revert still work. In the graph they’re hatched.">
      <SettingsGroup title="Built in" meta="builtin_immutable_heads()">
        <SettingsRow label="Trunk" hint={"Your main line. trunk() is " + trunkName + ", set under History."} configKey="trunk()">{sw("trunk", "Trunk")}</SettingsRow>
        <SettingsRow label="Tags" hint={"Released versions: " + list(tags) + "."} configKey="tags()">{sw("tags", "Tags")}</SettingsRow>
        <SettingsRow label="Remote bookmarks you don’t track" hint={"Fetched, but not yours to rewrite: " + list(remoteBookmarks) + "."} configKey="untracked_remote_bookmarks()">{sw("remoteBookmarks", "Remote bookmarks you don’t track")}</SettingsRow>
        <SettingsRow label="Remote tags you don’t track" hint={remoteTags.length ? "Fetched, but not yours to move: " + list(remoteTags) + "." : "None in this repository."} configKey="untracked_remote_tags()">{sw("remoteTags", "Remote tags you don’t track")}</SettingsRow>
      </SettingsGroup>
      <SettingsGroup title="Also immutable">
        <SettingsRow label="Other people’s changes" hint="Everything after trunk() that isn’t yours. What’s below them is locked too, your own changes included." configKey="trunk().. & ~mine()">{sw("others", "Other people’s changes")}</SettingsRow>
        <SettingsRow label="Bookmarks" hint="A release or shared branch you never rewrite." stack>
          <div className="zs-imm-chips">
            {c.bookmarks.map((b) => <Chip key={b} kind="filter" mono onRemove={() => set({ bookmarks: c.bookmarks.filter((x) => x !== b) })}>{b}</Chip>)}
            <span className="zs-imm-add" ref={addRef} title={choices.length ? undefined : "Every bookmark is in already"}>
              <Chip kind="add" disabled={!choices.length} aria-haspopup="menu" aria-expanded={adding} onClick={() => setAdding(!adding)}>Bookmark…</Chip>
              {adding && (
                <Menu autoFocus items={choices.map((b) => ({ id: b, text: b, label: <code className="zs-select-code">{b}</code> }))}
                  onSelect={(id) => { done(); set({ bookmarks: [...c.bookmarks, id] }); }} onClose={done} />
              )}
            </span>
          </div>
        </SettingsRow>
        <SettingsRow label="Custom revset" hint="Joined with |. The graph previews bookmark names, change ids, author() and description(); jj evaluates the rest." stack>
          <div className="zs-imm-col">
            <TextField mono value={c.custom} onChange={(e) => set({ custom: e.target.value })} placeholder={'description(glob:"hotfix:*")'} spellCheck={false} aria-label="Custom revset" />
            {unknown.length > 0 && <span className="zs-imm-unk">Not previewed here: <code>{unknown.join(" | ")}</code></span>}
          </div>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title="Result" bare>
        <div className="zs-imm-out">
          <pre className="zs-imm-toml">{"[revset-aliases]\n"}{trunkName !== "main" ? '"trunk()" = ' + zsTomlStr(trunkName) + "\n" : ""}<b>{'"immutable_heads()"'}</b>{" = " + zsTomlStr(expr)}</pre>
          {count != null && (
            <div className="zs-imm-sum">
              <span className="zs-imm-n"><HatchSwatch /><span><b>{count}</b> {count === 1 ? "change is" : "changes are"} immutable</span></span>
              {heads.length > 0 && <span className="zs-imm-heads">{heads.join(" · ")}</span>}
            </div>
          )}
        </div>
        <div className="zs-imm-note">
          <span>root() is always immutable. To rewrite one anyway, jj needs <code>--ignore-immutable</code>.</span>
          {expr !== "builtin_immutable_heads()" && <Button size="md" onClick={() => set(ZS_IMM_DEFAULTS)}>Reset to jj’s default</Button>}
        </div>
      </SettingsGroup>
    </SettingsPage>
  );
}
ImmutablePage.defaults = ZS_IMM_DEFAULTS;
ImmutablePage.builtins = ZS_IMM_BUILT.map(([key, fn, name]) => ({ key, fn, name }));
ImmutablePage.expr = (config) => zsImmExpr({ ...ZS_IMM_DEFAULTS, ...(config || {}) });
ImmutablePage.isDefault = (config) => ImmutablePage.expr(config) === "builtin_immutable_heads()";
ImmutablePage.summary = (config) => zsImmSummary({ ...ZS_IMM_DEFAULTS, ...(config || {}) });
ImmutablePage.toml = (config, trunkName = "main") => "[revset-aliases]\n" + (trunkName !== "main" ? '"trunk()" = ' + zsTomlStr(trunkName) + "\n" : "") + '"immutable_heads()" = ' + zsTomlStr(ImmutablePage.expr(config));
