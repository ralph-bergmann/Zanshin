import React from "react";

// ZANSHIN wordmark — monoline geometric strokes, A without crossbar, wide tracking. Pure paths, no font.
// Cap height = 100 units; stroke 7.37 units (2.8px at 38px). Gold gradient on night, ink on paper, white on black.
const ZS_WORDMARK_D = "M 0 0 L 62 0 L 0 100 L 62 100 M 94 100 L 126 0 L 158 100 M 190 100 L 190 0 L 252 100 L 252 0 M 339 19 A 27 22 0 1 0 313 50 A 27 22 0 1 1 287 81 M 374 0 L 374 100 M 436 0 L 436 100 M 374 50 L 436 50 M 468 0 L 468 100 M 500 100 L 500 0 L 562 100 L 562 0";
const ZS_WORDMARK_INK = { ink: "#26304d", white: "#f2f3f7" };
let zsWordSeq = 0;

export function Wordmark({ height = 38, variant = "gold", title = "Zanshin" }) {
  const uid = React.useMemo(() => "zs-word-" + ++zsWordSeq, []);
  const pad = 4, w = 562 + pad * 2, h = 100 + pad * 2;
  const stroke = ZS_WORDMARK_INK[variant] || "url(#" + uid + ")";
  return (
    <svg className="zs-wordmark" width={(height * w) / 100} height={(height * h) / 100} viewBox={-pad + " " + -pad + " " + w + " " + h} role="img" aria-label={title}>
      {!ZS_WORDMARK_INK[variant] && (
        <defs>
          <linearGradient id={uid} gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="224.8" y2="100">
            <stop offset="0" stopColor="#fff6e4"></stop><stop offset="0.5" stopColor="#f4cf80"></stop><stop offset="1" stopColor="#d9a755"></stop>
          </linearGradient>
        </defs>
      )}
      <path d={ZS_WORDMARK_D} fill="none" stroke={stroke} strokeWidth="7.37" strokeLinecap="butt" strokeLinejoin="miter"></path>
    </svg>
  );
}
