# Zanshin App Icons · Xcode 26 / Icon Composer

Four `.icon` bundles for the new Liquid Glass app icon format
(Xcode 26 / iOS 26 / macOS Tahoe and later).

## What's in here

```
xcode-icons/
├─ 01-Clean/          Zanshin-Clean.icon
├─ 02-BoldBrush/      Zanshin-BoldBrush.icon
├─ 03-DryBrush/       Zanshin-DryBrush.icon
└─ 04-NamiIndigo/     Zanshin-NamiIndigo.icon    ← your pick
```

Each `.icon` is a *package* (a folder Finder treats as a single file).
Right-click → **Show Package Contents** to peek inside. You'll find
`icon.json` plus an `Assets/` subfolder with each layer as a separate
1024×1024 SVG, white-on-transparent — exactly the layout Icon Composer
uses on disk.

## How to use

### Option A · Drag into Xcode (recommended)

1. Drag the `.icon` file (e.g. `Zanshin-NamiIndigo.icon`) into your Xcode 26
   project navigator.
2. In your target's **Build Settings** → **App Icon Set Name**, set the
   name to match the `.icon` file *without* the extension
   (e.g. `Zanshin-NamiIndigo`).
3. Build. Xcode generates a Liquid Glass icon for iOS/macOS 26 and a
   bitmap fallback for older OS versions automatically.

### Option B · Open in Icon Composer (to refine)

1. Double-click the `.icon` file → opens in Icon Composer
   (Xcode 26 → Open Developer Tool → Icon Composer).
2. If the stub `icon.json` doesn't load cleanly: create a fresh icon,
   drag the SVGs from `Assets/` onto the canvas, and dial in the fills
   from each design's `README.txt`.
3. Save (⌘S) — Icon Composer rewrites `icon.json` to its canonical form.
4. Tweak Liquid Glass properties (specular, shadow, dark mode, mono)
   per layer as you like.

## Notes

* SVGs use `viewBox="0 0 256 256"` and `width/height="1024"` so they
  render at the canvas size Icon Composer expects.
* Foreground shapes are white on transparent — fill colors are
  assigned in `icon.json` / via the Fill picker in Icon Composer.
  This is Apple's recommended setup so the layer can adapt to
  Dark / Mono / Tinted modes.
* The `icon.json` stub here is a best-effort: Apple hasn't published
  the schema, so Icon Composer may renormalise it on first save.
  The `Assets/*.svg` files are the durable part.
