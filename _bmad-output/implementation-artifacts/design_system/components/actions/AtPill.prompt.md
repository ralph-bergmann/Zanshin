Floating pill that scrolls back to the working copy; render it only while @ is out of view, bottom-centre of the graph.

~~~jsx
{wcOffscreen && <AtPill direction="up" onClick={scrollToWc} />}
~~~

- Never a permanent button — it appears with a 320ms glide and disappears when @ is visible again.
