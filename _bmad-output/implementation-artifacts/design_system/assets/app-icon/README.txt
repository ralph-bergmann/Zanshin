Zanshin-NamiIndigo.icon
-----------------------

Nami · Indigo — three layered sumi-e waves. An Icon Composer bundle (icon.json in Icon Composer's
own schema), byte-equal to the app's app/macos/Runner/NamiIndigo.icon.

Background fill (linear gradient, top → bottom):
  · #1d2540 @ 0
  · #131831 @ 1

Layers (in order). Each wave is an open path STROKED in its color in the SVG itself; the layer has
no fill ("fill" : "none") — a solid layer fill would paint the area each open path encloses and
render three crescents instead of waves (2026-10-31, Story 11.10):
  · Wave-Top.svg         → stroke #f4cf80
  · Wave-Mid.svg         → stroke #dca85b
  · Wave-Bottom.svg      → stroke #b58346
