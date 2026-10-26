Small status pill for the inspector header (Working copy, Immutable, Empty, Conflict).

~~~jsx
<Flag kind="wc">Working copy</Flag>  <Flag icon={<HatchSwatch/>} title="Immutable · below trunk() · main">Immutable</Flag>  <Flag kind="warn" icon="conflict">Conflict</Flag>
~~~

- Immutable carries the hatch swatch, never a ◆; its `title` is the reason (the immutable head that locks it). No colour — neutral like Empty and Merge.
