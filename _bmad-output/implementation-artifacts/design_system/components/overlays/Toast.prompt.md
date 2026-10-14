The undo toast that follows every graph edit (drop, squash, split, commit, abandon).

~~~jsx
<Toast onUndo={undo} onClose={dismiss}>Moved <ChangeId id="ovknlmro" length={8}/> onto <ChangeId id="vruxwmqv" length={8}/></Toast>
~~~

- Past-tense verb first, then the ids: "Squashed … into …", "Inserted … after …", "Abandoned …", "Committed … · “msg”".
- 38px glass pill, bottom centre, 20px from the edge; Undo is a 28px quiet pill (`jj undo`), × dismisses. Auto-hides after 6.5s.
- One toast at a time; a new edit replaces it.
