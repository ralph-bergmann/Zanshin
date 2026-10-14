Popover sheet for view/settings options that hang off an island button; compose with PopoverHeader, OptionRow and PopoverSeparator.

~~~jsx
<Popover>
  <PopoverHeader>Graph</PopoverHeader>
  <OptionRow label="Layout"><Segmented options={["Compact", "Time"]} value="Compact" /></OptionRow>
  <OptionRow label="Detailed cards"><Switch checked /></OptionRow>
  <PopoverSeparator />
  <PopoverHeader>Appearance</PopoverHeader>
</Popover>
~~~

- Opens 14px below its island, right-aligned; enters with a 160ms glide (translateY −4px, scale .98).
