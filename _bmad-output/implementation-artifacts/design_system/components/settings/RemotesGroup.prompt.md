The git remotes in Settings › Project (sync #20, Story 11.18) — `jj git remote list / add / rename / set-url / remove`, then the group's other rows.

~~~jsx
<RemotesGroup remotes={[{ name: "origin", url: "git@github.com:ralph/myapp.git" }, { name: "upstream", url: "https://github.com/acme/myapp.git", pushUrl: "git@github.com:ralph/myapp.git" }]}
  onRun={(op) => bridge.run(op) /* null · { refusal: { message, help } } · { warning: { message, hint } } */}>
  <SettingsRow label="Fetch from" configKey="git.fetch"><Select … /></SettingsRow>
  <SettingsRow label="Push to" configKey="git.push"><Select … /></SettingsRow>
</RemotesGroup>
~~~

- **A row** — the name (`--fs-base`), the fetch URL (mono `--fs-id`, `--text-dim`, one line, ellipsis at the end, the full URL as tooltip), the push URL as a second line `push …` only when it differs. A push-only remote reads *No fetch URL*. The Settings window is resizable, so a wider window shows more of the URL — never wrap a URL.
- **A credential never shows** — rows, fields, commands and tooltips hide everything between `scheme://` and `@` (`https://•••@git.example.com/…`; `RemotesGroup.scrub`). Set URL on such a remote starts the field empty with the hidden form as placeholder: type a new URL to replace it.
- **••• →** Rename… · Set URL… · — · Remove… (`Menu`, the command in the right column). **Add remote…** is the list's last row (`+`, the add verb as tooltip).
- **The row as a form** (Add · Rename · Set URL — the Projects window's in-place rename, grown): the row takes `--fl-on`, the fields sit on a 72px label column, then the **command well** (the exact command, shell-quoted, credentials hidden — `RemotesGroup.command`), then Cancel + the verb (gold primary, off until something would change). ↩ runs it, Esc cancels. Set URL sends only the sides that change; an empty field leaves its side alone (jj can set a URL, not remove one). Add's push-URL hint says jj can't remove such a remote later.
- **Refusals** — jj's message verbatim in `--warn` with the `conflict` mark, under the form (it stays open, the field marked) or under the row (Remove). Where jj's words need it, one plain sentence follows (`--text-muted`): the reserved name `git`, a *nonstandard configuration* (a push URL or other git keys jj doesn't manage — `git remote remove <name>` removes it). A warning after Add (*Remote origin already uses the same URL.* + jj's hint) shows under the new row the same way.
- **Remove** asks first — `ConfirmDialog` destructive, as a sheet on the Settings window: "Remove upstream?" · its remote bookmarks leave, git forgets the URLs, your own bookmarks and changes stay, `jj undo` can't bring the URLs back · the command · **Remove remote**. No undo toast for any remote verb: `jj undo` would revert the remote bookmarks but not git's config.
- After any verb the app reads the remotes again; the Fetch from / Push to selects offer what the list holds — a removed remote stays named in its select as "upstream — not a remote" (jj doesn't rewrite `git.fetch` / `git.push`).
- Keyboard · VoiceOver · Reduce motion: ••• is a Tab stop per row; the form's first field takes focus (Rename selects the name); Esc returns focus to the row's •••; the refusal is an alert · rows read "origin, git@github.com:ralph/myapp.git" · nothing moves.
