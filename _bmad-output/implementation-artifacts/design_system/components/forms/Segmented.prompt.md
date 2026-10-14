Segmented control for 2–4 exclusive choices inside option rows (layout, theme, density).

~~~jsx
<Segmented label="Theme" value="dark" onChange={setTheme} options={[
  { value: "light", label: "Light", icon: "sun" }, { value: "dark", label: "Dark", icon: "moon" }, { value: "system", label: "Auto", icon: "auto" },
]} />
~~~
