import React from "react";

// Zanshin UI icons — 16px grid, one 1.5 stroke, round caps and joins, currentColor; solids only where meaning needs one.
// Generated from assets/icons/ui/*.svg — the source. The Flutter app renders those same files (precompiled at build time, tinted in one colour).
const ZS_ICON_SET = {
  "abandon": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5\"></path></g>",
  "alert": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"5.75\"></circle><path d=\"M8 5.5v2.25\"></path><circle cx=\"8\" cy=\"10.35\" r=\"0.85\" fill=\"currentColor\" stroke=\"none\"></circle></g>",
  "arrow-up": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 13.25V3M4.5 6.5L8 3l3.5 3.5\"></path></g>",
  "auto": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"5.5\"></circle><path d=\"M8 2.5v11\"></path><path d=\"M8 2.5a5.5 5.5 0 0 0 0 11z\" fill=\"currentColor\" stroke=\"none\"></path></g>",
  "bookmark": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z\"></path></g>",
  "bookmark-filled": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z\" fill=\"currentColor\"></path></g>",
  "branch": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"4\" cy=\"4\" r=\"1.75\"></circle><circle cx=\"4\" cy=\"12\" r=\"1.75\"></circle><circle cx=\"12\" cy=\"8\" r=\"1.75\"></circle><path d=\"M4 5.75v4.5M5.75 4q3 0 5 2.5\"></path></g>",
  "calendar": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"3.5\" width=\"11\" height=\"10\" rx=\"1.5\"></rect><path d=\"M2.5 6.5h11M5.5 1.75V4M10.5 1.75V4\"></path></g>",
  "change": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2.5\"></circle><path d=\"M1.75 8h3.75M10.5 8h3.75\"></path></g>",
  "check": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 8.5l3 3 7-7\"></path></g>",
  "chevron-down": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.5 6.25l3.5 3.5 3.5-3.5\"></path></g>",
  "chevron-left": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M9.75 4.5L6.25 8l3.5 3.5\"></path></g>",
  "chevron-right": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6.25 4.5L9.75 8l-3.5 3.5\"></path></g>",
  "chevron-up": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.5 9.75L8 6.25l3.5 3.5\"></path></g>",
  "close": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3.5 3.5l9 9M12.5 3.5l-9 9\"></path></g>",
  "cloud": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.55 12.5h7a2.5 2.5 0 0 0 .3-4.98A3.5 3.5 0 0 0 5.05 6.5 2.75 2.75 0 0 0 4.55 12.5z\"></path></g>",
  "conflict": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.75L1.75 13.5h12.5z\"></path><path d=\"M8 6.05v2.25\"></path><circle cx=\"8\" cy=\"10.9\" r=\"0.85\" fill=\"currentColor\" stroke=\"none\"></circle></g>",
  "copy": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"></rect><path d=\"M2.5 10.5V4A1.5 1.5 0 0 1 4 2.5h6.5\"></path></g>",
  "describe": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 13l1-3 7-7 2 2-7 7-3 1z\"></path><path d=\"M9.25 4.75l2 2\"></path></g>",
  "description": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 4.5h10M3 8h10M3 11.5h6\"></path></g>",
  "duplicate": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"></rect><path d=\"M2.5 10.5V4A1.5 1.5 0 0 1 4 2.5h6.5M9.5 8v3M8 9.5h3\"></path></g>",
  "fetch": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2v8M5 7l3 3 3-3M3 13h10\"></path></g>",
  "file": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 2h5l3 3v9H4V2z\"></path><path d=\"M9 2v3h3\"></path></g>",
  "file-text": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 2h5l3 3v9H4V2z\"></path><path d=\"M9 2v3h3M6.5 8.5h3M6.5 11H8\"></path></g>",
  "folder": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 12.5V3.5h4L8 5h5.5v7.5H2.5z\"></path></g>",
  "folder-open": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 12.5V3.5h4L8 5h4.5v2\"></path><path d=\"M2.5 12.5l1.75-5h10l-1.75 5h-10z\"></path></g>",
  "folder-plus": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 12.5V3.5h4L8 5h5.5v7.5H2.5z\"></path><path d=\"M8 7.5v2.5M6.75 8.75h2.5\"></path></g>",
  "grip": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"6\" cy=\"4\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"10\" cy=\"4\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"6\" cy=\"8\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"10\" cy=\"8\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"6\" cy=\"12\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"10\" cy=\"12\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle></g>",
  "hash": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6 2l-1 12M11 2l-1 12M2.5 5.5h11M2 10.5h11\"></path></g>",
  "history": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"5.5\"></circle><path d=\"M8 5v3l1.9 1.9\"></path></g>",
  "home": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 7.5L8 2.5l5.5 5M4 7v6.5h8V7\"></path></g>",
  "insert-after": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3.5 2h9M8 4.5V8M6.25 6.25h3.5\"></path><rect x=\"2.5\" y=\"10.5\" width=\"11\" height=\"3.5\" rx=\"1.5\"></rect></g>",
  "insert-before": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"2\" width=\"11\" height=\"3.5\" rx=\"1.5\"></rect><path d=\"M8 8v3.5M6.25 9.75h3.5M3.5 14h9\"></path></g>",
  "merge": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"3.5\" r=\"1.75\"></circle><circle cx=\"4.5\" cy=\"12.5\" r=\"1.75\"></circle><circle cx=\"11.5\" cy=\"12.5\" r=\"1.75\"></circle><path d=\"M4.5 10.75V10c0-1.75 3.5-2.25 3.5-4.75M11.5 10.75V10c0-1.75-3.5-2.25-3.5-4.75\"></path></g>",
  "merge-new": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"4.5\" cy=\"12.5\" r=\"1.75\"></circle><circle cx=\"11.5\" cy=\"12.5\" r=\"1.75\"></circle><path d=\"M8 1.75v3.5M6.25 3.5h3.5M4.5 10.75V10c0-1.75 3.5-2.25 3.5-4.75M11.5 10.75V10c0-1.75-3.5-2.25-3.5-4.75\"></path></g>",
  "minus": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 8h10\"></path></g>",
  "moon": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M13.4 8.47A5.4 5.4 0 1 1 7.33 2.6 4.2 4.2 0 0 0 13.4 8.47z\"></path></g>",
  "more": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"3.5\" cy=\"8\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"8\" cy=\"8\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle><circle cx=\"12.5\" cy=\"8\" r=\"1.25\" fill=\"currentColor\" stroke=\"none\"></circle></g>",
  "move-only": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5\" y=\"1.75\" width=\"6\" height=\"2.5\" rx=\"1.25\"></rect><path d=\"M8 6.75v2.5M6.25 7.5L8 9.25l1.75-1.75\"></path><rect x=\"2.5\" y=\"11.75\" width=\"11\" height=\"2.5\" rx=\"1.25\"></rect></g>",
  "move-onto": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.75V8M5 5l3 3 3-3\"></path><rect x=\"2.5\" y=\"10.5\" width=\"11\" height=\"3.5\" rx=\"1.5\"></rect></g>",
  "new-on-top": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2v5.5M5.25 4.75h5.5\"></path><rect x=\"2.5\" y=\"10.5\" width=\"11\" height=\"3.5\" rx=\"1.5\"></rect></g>",
  "plus": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 3v10M3 8h10\"></path></g>",
  "pull": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.75v6M5 4.75l3 3 3-3\"></path><circle cx=\"8\" cy=\"12\" r=\"1.75\"></circle></g>",
  "push": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 13V5M5 8l3-3 3 3M3 2h10\"></path></g>",
  "reviews": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 11.5V4a1 1 0 0 1 1-1h7l3 3v5.5a1 1 0 0 1-1 1H6L3 14v-2.5z\"></path></g>",
  "search": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"7\" cy=\"7\" r=\"4\"></circle><path d=\"M10 10l3.5 3.5\"></path></g>",
  "settings": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6.79 3.77L6.96 2.09A6 6 0 0 1 9.04 2.09L9.21 3.77A4.4 4.4 0 0 1 11.06 4.83L12.6 4.14A6 6 0 0 1 13.64 5.95L12.27 6.94A4.4 4.4 0 0 1 12.27 9.06L13.64 10.05A6 6 0 0 1 12.6 11.86L11.06 11.17A4.4 4.4 0 0 1 9.21 12.23L9.04 13.91A6 6 0 0 1 6.96 13.91L6.79 12.23A4.4 4.4 0 0 1 4.94 11.17L3.4 11.86A6 6 0 0 1 2.36 10.05L3.73 9.06A4.4 4.4 0 0 1 3.73 6.94L2.36 5.95A6 6 0 0 1 3.4 4.14L4.94 4.83A4.4 4.4 0 0 1 6.79 3.77z\"></path><circle cx=\"8\" cy=\"8\" r=\"1.85\"></circle></g>",
  "split-inline": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.5\"></rect><path d=\"M2 8h12\"></path></g>",
  "split-side": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.5\"></rect><path d=\"M8 3v10\"></path></g>",
  "squash": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.75V5.5M5.75 3.25L8 5.5l2.25-2.25M8 14.25V10.5M5.75 12.75L8 10.5l2.25 2.25M2.5 8h11\"></path></g>",
  "squash-into": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 9v3.5A1.5 1.5 0 0 0 4 14h8a1.5 1.5 0 0 0 1.5-1.5V9\"></path><path d=\"M8 1.75v8.5M5 7.25l3 3 3-3\"></path></g>",
  "stack-collapse": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"8\" width=\"7\" height=\"6\" rx=\"1.5\"></rect><path d=\"M4.5 5.5h5.5A1.5 1.5 0 0 1 11.5 7v4.5M7 3h5.5A1.5 1.5 0 0 1 14 4.5V9\"></path></g>",
  "sun": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2.25\"></circle><path d=\"M8 2v1.25M8 12.75V14M14 8h-1.25M3.25 8H2M12.45 3.55l-1.09 1.09M4.64 11.36l-1.09 1.09M12.45 12.45l-1.09-1.09M4.64 4.64L3.55 3.55\"></path></g>",
  "undo": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6 3.5L3 6.5l3 3\"></path><path d=\"M3 6.5h7a3.5 3.5 0 0 1 0 7H6\"></path></g>",
  "updown": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M5 6.25L8 3.5l3 2.75M5 9.75L8 12.5l3-2.75\"></path></g>",
  "user": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"5.25\" r=\"2.25\"></circle><path d=\"M3 14c0-2.25 2.2-4 5-4s5 1.75 5 4\"></path></g>",
  "view-options": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 5h1.6M7.9 5h5.6M2.5 11h6.1M12.4 11h1.1\"></path><circle cx=\"6\" cy=\"5\" r=\"1.9\"></circle><circle cx=\"10.5\" cy=\"11\" r=\"1.9\"></circle></g>",
  "working-copy-at": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2.25\"></circle><path d=\"M10.25 5.75V9.1c0 1.05.7 1.9 1.7 1.9 1.25 0 1.8-1.4 1.8-3A5.75 5.75 0 1 0 10.9 13\"></path></g>",
};
// retired names → their glyph, so older calls keep working
const ZS_ICON_ALIASES = {"download":"fetch","stacked-on":"arrow-up","add":"plus","check-bold":"check","dash-bold":"minus","more-bold":"more","grip-dots":"grip","arrow-left":"chevron-left","edit":"describe"};

// Sizes = the --icon-* tokens (tokens/spacing.css): pass a name or a number in px.
const ZS_ICON_SIZES = { xs: 10, sm: 12, md: 14, lg: 16, bar: 17, rail: 19 };
export function Icon({ name, size: sizeIn = "lg", title, className = "", style, ...rest }) {
  const size = typeof sizeIn === "string" ? (ZS_ICON_SIZES[sizeIn] || 16) : sizeIn;
  const d = ZS_ICON_SET[name] || ZS_ICON_SET[ZS_ICON_ALIASES[name]];
  if (!d) return null;
  const [vb, inner] = Array.isArray(d) ? d : ["0 0 16 16", d];
  return (
    <svg className={("zs-icon " + className).trim()} width={size} height={size} viewBox={vb} role={title ? "img" : undefined} aria-hidden={title ? undefined : true}
      style={style} {...rest} dangerouslySetInnerHTML={{ __html: (title ? "<title>" + title + "</title>" : "") + inner }}></svg>
  );
}
Icon.names = Object.keys(ZS_ICON_SET);
Icon.sizes = ZS_ICON_SIZES;
