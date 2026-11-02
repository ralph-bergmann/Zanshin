Renders a jj change id the way jj does — the unique two-character prefix bold, the rest faint. No ◆ for immutable (retired): the card's hatch says it.

~~~jsx
<ChangeId id="kmnvxoqp" />          {/* km nvx */}
<ChangeId id="wlyrtqpz" length={8} />
~~~

The inspector header has a copy variant (Story 10.30; ui kit `ZKCopyId`): the short change id (max(prefix, 8)) with a faint, lowered `jj` subscript beside the short commit id with `git`. A click copies the **full** id — tooltip "Click to copy" over the full id (mono), "Copied" for a moment; a failed clipboard write opens a small popover with the full id as selectable text until a click outside or Esc. The parents in the meta line copy the same way. Graph cards and the peek keep click = select.
