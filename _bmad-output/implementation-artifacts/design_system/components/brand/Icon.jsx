import React from "react";

// Zanshin UI icons — 16px grid, 1.3–1.6 stroke, round caps, currentColor. Generated from icons/ui/*.svg.
const ZS_ICON_SET = {
  "abandon": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5\"></path></g>",
  "arrow-left": "<path d=\"M9.5 4L5.5 8l4 4\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "auto": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\"><circle cx=\"8\" cy=\"8\" r=\"5.5\"></circle><path d=\"M8 2.5v11\" stroke=\"currentColor\" stroke-width=\"1.4\"></path><path d=\"M8 2.5a5.5 5.5 0 0 0 0 11\" fill=\"currentColor\" stroke=\"none\"></path></g>",
  "bookmark-filled": "<path d=\"M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z\" fill=\"currentColor\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linejoin=\"round\"></path>",
  "bookmark": "<path d=\"M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linejoin=\"round\"></path>",
  "branch": "<g stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\"><circle cx=\"4\" cy=\"4\" r=\"1.8\"></circle><circle cx=\"4\" cy=\"12\" r=\"1.8\"></circle><circle cx=\"12\" cy=\"8\" r=\"1.8\"></circle><path d=\"M4 5.8v4.4M5.6 4q3 0 5 2.5\"></path></g>",
  "calendar": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\"><rect x=\"2.5\" y=\"3.5\" width=\"11\" height=\"10\" rx=\"1\"></rect><path d=\"M2.5 6.5h11M5.5 2v3M10.5 2v3\"></path></g>",
  "check": "<path d=\"M3 8.5l3 3 7-7\" stroke=\"currentColor\" stroke-width=\"1.6\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "chevron-down": "<path d=\"M4.5 6.5l3.5 3.5 3.5-3.5\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "chevron-right": "<path d=\"M6 4l4 4-4 4\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "close": "<path d=\"M3.5 3.5l9 9M12.5 3.5l-9 9\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\"></path>",
  "cloud": "<path d=\"M4.5 12.5h7a2.5 2.5 0 0 0 .3-4.98A3.5 3.5 0 0 0 5 6.5 2.75 2.75 0 0 0 4.5 12.5z\" stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\" stroke-linejoin=\"round\"></path>",
  "conflict": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.5L1.5 13.5h13L8 1.5z\"></path><path d=\"M8 6v3.5M8 11v0.4\"></path></g>",
  "describe": "<path d=\"M3 13l.6-2.6L10.5 3.5l2 2-6.9 6.9L3 13zM9.3 4.7l2 2\" stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linejoin=\"round\"></path>",
  "download": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2v8M5 7l3 3 3-3\"></path><path d=\"M3 13h10\"></path></g>",
  "edit": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 13l1-3 7-7 2 2-7 7-3 1z\"></path><path d=\"M10 3.5l2 2\"></path></g>",
  "fetch": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M8 2v8\"></path><path d=\"M5 7l3 3 3-3\"></path><path d=\"M3 13h10\"></path></g>",
  "file-text": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\" stroke-linejoin=\"round\"><path d=\"M4 2h5l3 3v9H4V2z\"></path><path d=\"M9 2v3h3M6 8.5h4M6 11h3\" stroke-linecap=\"round\"></path></g>",
  "file": "<path d=\"M4 2h5l3 3v9H4V2z\" stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linejoin=\"round\"></path>",
  "folder-open": "<path d=\"M2.5 13V5h4l1.5 1.5h5.5V8M2.5 13l1.8-5h11l-1.8 5h-11z\" stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\" stroke-linejoin=\"round\" stroke-linecap=\"round\"></path>",
  "folder-plus": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\" stroke-linejoin=\"round\"><path d=\"M2.5 13V4.5h4L8 6h5.5V13H2.5z\"></path><path d=\"M8 8.5v3M6.5 10h3\" stroke-linecap=\"round\"></path></g>",
  "folder": "<path d=\"M3 5.5h4.5l1.5 1.5h6V14H3V5.5z\" stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linejoin=\"round\"></path>",
  "grip": "<g fill=\"currentColor\"><circle cx=\"6\" cy=\"4\" r=\"1.1\"></circle><circle cx=\"10\" cy=\"4\" r=\"1.1\"></circle><circle cx=\"6\" cy=\"8\" r=\"1.1\"></circle><circle cx=\"10\" cy=\"8\" r=\"1.1\"></circle><circle cx=\"6\" cy=\"12\" r=\"1.1\"></circle><circle cx=\"10\" cy=\"12\" r=\"1.1\"></circle></g>",
  "hash": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M6 2l-1 12M11 2l-1 12M2.5 5.5h11M2 10.5h11\"></path></g>",
  "history": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><circle cx=\"8\" cy=\"8\" r=\"5.5\"></circle><path d=\"M8 4.5V8l2.2 2.2\"></path></g>",
  "home": "<path d=\"M2.5 7.5L8 2.5l5.5 5M4 7v6.5h8V7\" stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linejoin=\"round\" stroke-linecap=\"round\"></path>",
  "merge": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M5 3v6a3 3 0 0 0 3 3h3\"></path><circle cx=\"5\" cy=\"3\" r=\"1.5\"></circle><circle cx=\"11\" cy=\"12\" r=\"1.5\"></circle></g>",
  "moon": "<path d=\"M12.5 8.5A5.5 5.5 0 1 1 7.5 3.5a4.5 4.5 0 0 0 5 5z\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linejoin=\"round\"></path>",
  "more": "<g fill=\"currentColor\"><circle cx=\"3.5\" cy=\"8\" r=\"1.1\"></circle><circle cx=\"8\" cy=\"8\" r=\"1.1\"></circle><circle cx=\"12.5\" cy=\"8\" r=\"1.1\"></circle></g>",
  "plus": "<path d=\"M8 3v10M3 8h10\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\"></path>",
  "pull": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M8 2v6\"></path><path d=\"M5 5l3 3 3-3\"></path><circle cx=\"8\" cy=\"12\" r=\"1.5\"></circle></g>",
  "push": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M8 13V5\"></path><path d=\"M5 8l3-3 3 3\"></path><path d=\"M3 2h10\"></path></g>",
  "reviews": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M3 11.5V4a1 1 0 0 1 1-1h7l3 3v5.5a1 1 0 0 1-1 1H6L3 14v-2.5z\"></path></g>",
  "search": "<g stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\"><circle cx=\"7\" cy=\"7\" r=\"4\"></circle><path d=\"M10 10l3.5 3.5\"></path></g>",
  "settings": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\"><circle cx=\"8\" cy=\"8\" r=\"2.2\"></circle><path d=\"M8 1.5v1.6M8 12.9v1.6M14.5 8h-1.6M3.1 8H1.5M12.6 3.4l-1.1 1.1M4.5 11.5l-1.1 1.1M12.6 12.6l-1.1-1.1M4.5 4.5L3.4 3.4\"></path></g>",
  "split-inline": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.2\"></rect><path d=\"M2 8h12\"></path></g>",
  "split-side": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.2\"></rect><path d=\"M8 3v10\"></path></g>",
  "squash": "<g stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2v7M5 6l3 3 3-3\"></path><path d=\"M3 13h10\"></path></g>",
  "stack-collapse": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"6.5\" width=\"9\" height=\"7.5\" rx=\"1.5\"></rect><path d=\"M5 4h8.5a.5.5 0 0 1 .5.5V11\"></path><path d=\"M8 1.5h7.5\"></path></g>",
  "stacked-on": "<path d=\"M8 3v10M5 6l3-3 3 3\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "sun": "<g stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2.8\"></circle><path d=\"M8 1.5V3M8 13v1.5M14.5 8H13M3 8H1.5M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7L3.6 3.6\"></path></g>",
  "undo": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M3.5 6.5H10a3.5 3.5 0 1 1 0 7H6\"></path><path d=\"M5.5 4L3 6.5 5.5 9\"></path></g>",
  "user": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\"><circle cx=\"8\" cy=\"6\" r=\"2.5\"></circle><path d=\"M3 14c0-2.5 2.2-4.5 5-4.5s5 2 5 4.5\"></path></g>",
  "view-options": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><path d=\"M2.5 5h1.6M7.9 5h5.6M2.5 11h6.1M12.4 11h1.1\"></path><circle cx=\"6\" cy=\"5\" r=\"1.9\"></circle><circle cx=\"10.5\" cy=\"11\" r=\"1.9\"></circle></g>",
  "working-copy-at": "<text x=\"8\" y=\"12\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"700\" fill=\"currentColor\" font-family=\"ui-monospace,monospace\">@</text>",
  "workstream": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\"><circle cx=\"3.5\" cy=\"4\" r=\"1.5\"></circle><circle cx=\"3.5\" cy=\"12\" r=\"1.5\"></circle><circle cx=\"12.5\" cy=\"4\" r=\"1.5\"></circle><circle cx=\"12.5\" cy=\"12\" r=\"1.5\"></circle><path d=\"M3.5 5.5v5M12.5 5.5v5M5 4h6M5 12h6\"></path></g>",
  // added from the floating client: @ locator arrow (app-float), drop-menu + quick-action glyphs (graph-dnd, graph-view), checkbox marks (inspector)
  "arrow-up": "<path d=\"M8 13V3.5M4 7.5l4-4 4 4\" stroke=\"currentColor\" stroke-width=\"1.6\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "add": "<path d=\"M8 2.5v11M2.5 8h11\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\"></path>",
  "check-bold": "<path d=\"M3 8.5l3 3 7-7\" stroke=\"currentColor\" stroke-width=\"2.2\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "dash-bold": "<path d=\"M4 8h8\" stroke=\"currentColor\" stroke-width=\"2.2\" stroke-linecap=\"round\"></path>",
  "more-bold": "<g fill=\"currentColor\"><circle cx=\"3.5\" cy=\"8\" r=\"1.4\"></circle><circle cx=\"8\" cy=\"8\" r=\"1.4\"></circle><circle cx=\"12.5\" cy=\"8\" r=\"1.4\"></circle></g>",
  "new-on-top": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"10\" width=\"11\" height=\"4\" rx=\"1.2\"></rect><path d=\"M8 1.75v5.5M5.25 4.5h5.5\"></path></g>",
  "insert-after": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3.5 1.75h9\"></path><path d=\"M8 4v4.5M5.75 6.25h4.5\"></path><rect x=\"2.5\" y=\"10.5\" width=\"11\" height=\"3.75\" rx=\"1.2\"></rect></g>",
  "insert-before": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"1.75\" width=\"11\" height=\"3.75\" rx=\"1.2\"></rect><path d=\"M8 7.5v4.5M5.75 9.75h4.5\"></path><path d=\"M3.5 14.25h9\"></path></g>",
  "move-onto": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2v8.5M4.5 7l3.5 3.5L11.5 7\"></path><path d=\"M3 14h10\"></path></g>",
  "move-only": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5\" y=\"1.5\" width=\"6\" height=\"4.5\" rx=\"1.2\"></rect><path d=\"M8 7.5v3.5M6 9.5l2 2 2-2\"></path><path d=\"M3 14h10\"></path></g>",
  "squash-into": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"9\" width=\"11\" height=\"5\" rx=\"1.3\"></rect><path d=\"M8 1.5v5.5M5.5 4.5L8 7l2.5-2.5\"></path></g>",
  "merge-new": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"8\" cy=\"3\" r=\"1.6\"></circle><path d=\"M8 4.6V7c0 2-4 2-4 4.5V14M8 7c0 2 4 2 4 4.5V14\"></path></g>",
  "duplicate": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"></rect><path d=\"M3 10.5V3.5a1 1 0 0 1 1-1h7\"></path></g>",
  // added from the floating client's graph search (graph-search.jsx): the Change and Description scope glyphs
  "change": "<g stroke=\"currentColor\" stroke-width=\"1.4\" fill=\"none\" stroke-linecap=\"round\"><circle cx=\"8\" cy=\"8\" r=\"2.6\"></circle><path d=\"M1.5 8h3.9M10.6 8h3.9\"></path></g>",
  "description": "<path d=\"M3 4.5h10M3 8h10M3 11.5h6\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\"></path>",
  // the configurations dialog's list toolbar (revset-config.jsx): remove, duplicate, move up
  "minus": "<path d=\"M3 8h10\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\"></path>",
  "copy": "<g stroke=\"currentColor\" stroke-width=\"1.3\" fill=\"none\"><rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"></rect><path d=\"M10.5 3.5V3A1.5 1.5 0 0 0 9 1.5H4A1.5 1.5 0 0 0 2.5 3v5A1.5 1.5 0 0 0 4 9.5h.5\"></path></g>",
  "chevron-up": "<path d=\"M4.5 9.5L8 6l3.5 3.5\" stroke=\"currentColor\" stroke-width=\"1.5\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"></path>",
  "grip-dots": ["0 0 10 12","<g fill=\"currentColor\"><circle cx=\"3\" cy=\"2.5\" r=\"1\"></circle><circle cx=\"7\" cy=\"2.5\" r=\"1\"></circle><circle cx=\"3\" cy=\"6\" r=\"1\"></circle><circle cx=\"7\" cy=\"6\" r=\"1\"></circle><circle cx=\"3\" cy=\"9.5\" r=\"1\"></circle><circle cx=\"7\" cy=\"9.5\" r=\"1\"></circle></g>"]
};

export function Icon({ name, size = 16, title, className = "", style, ...rest }) {
  const d = ZS_ICON_SET[name];
  if (!d) return null;
  const [vb, inner] = Array.isArray(d) ? d : ["0 0 16 16", d];
  return (
    <svg className={("zs-icon " + className).trim()} width={size} height={size} viewBox={vb} role={title ? "img" : undefined} aria-hidden={title ? undefined : true}
      style={style} {...rest} dangerouslySetInnerHTML={{ __html: (title ? "<title>" + title + "</title>" : "") + inner }}></svg>
  );
}
Icon.names = Object.keys(ZS_ICON_SET);
