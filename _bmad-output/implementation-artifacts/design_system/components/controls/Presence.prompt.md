Mount/unmount helper so every floating layer can play its exit.

~~~jsx
<Presence open={menuOpen}>{(closing) => <Menu closing={closing} items={items} onSelect={(id) => { run(id); setMenuOpen(false); }} />}</Presence>
<Presence open={!!confirm} exit={180}>{(closing) => <ConfirmDialog closing={closing} … />}</Presence>
~~~

- Exits: menus, popovers, callouts, select lists, tooltips fade out in `--dur-exit` (120ms); dialogs and toasts `--dur-exit-lg` (180ms) — all on `--ease-exit`, with at most a 2–8px drift back the way they came.
- Keyboard · VoiceOver · Reduce motion: none of its own — it keeps the layer mounted for its exit; the exit fades in place.
