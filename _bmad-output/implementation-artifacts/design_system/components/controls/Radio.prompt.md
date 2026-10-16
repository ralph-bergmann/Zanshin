Radio group for one choice among options that need a sentence each (merge strategy, what Push sends). 2–3 short words in a row → `Segmented`.

~~~jsx
<RadioGroup label="When @ has changes" value={mode} onChange={setMode} options={[
  { value: "new", label: "Start a new change", hint: "jj new — @ stays as it is" },
  { value: "squash", label: "Squash into @", hint: "jj squash" },
  { value: "ask", label: "Ask every time", disabled: true, title: "Needs Zanshin 0.25" },
]} />
~~~

- 15px circle, 1.5px `--text-faint` edge; hover `--text-muted` edge; pressed `--fl-on`; on = `--accent` fill + 6px `--accent-ink` dot that grows in (`--dur-toggle`, glide); on + hover lays `--fill-on-hover`; disabled .4 (row and label together); focus = the 2px ring.
- Clicking the label chooses. Keyboard: one tab stop; arrows move and choose. VoiceOver: radio group / radio.
