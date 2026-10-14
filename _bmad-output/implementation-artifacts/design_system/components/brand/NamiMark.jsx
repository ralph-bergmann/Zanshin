import React from "react";

// Nami — the Zanshin mark: three gold waves on indigo (app icon #04).
// Optical sizing: at chrome sizes (≤ 48px) the waves are drawn heavier (13/15/17) so they hold at 28px; larger sizes use the icon's 9/11/13.
const ZS_NAMI_WAVES = [
  ["M 28 92 Q 72 60, 116 92 T 196 92 Q 218 84, 228 90", "#f4cf80", 9, 13],
  ["M 24 134 Q 76 100, 132 134 T 212 134 Q 226 130, 234 134", "#dca85b", 11, 15],
  ["M 22 178 Q 88 138, 154 178 T 234 178", "#b58346", 13, 17],
];
let zsNamiSeq = 0;

export function NamiMark({ size = 28, chip = false, bare = false, title = "Zanshin" }) {
  const uid = React.useMemo(() => "zs-nami-" + ++zsNamiSeq, []);
  const heavy = size <= 48;
  const svg = (
    <svg className="zs-mark" width={size} height={size} viewBox="0 0 256 256" role="img" aria-label={title}>
      {!bare && (
        <defs>
          <linearGradient id={uid + "-bg"} x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#1d2540"></stop><stop offset="1" stopColor="#131831"></stop></linearGradient>
          <radialGradient id={uid + "-gl"} cx="0.5" cy="0.6" r="0.7"><stop offset="0" stopColor="#dca85b" stopOpacity="0.1"></stop><stop offset="1" stopColor="#dca85b" stopOpacity="0"></stop></radialGradient>
        </defs>
      )}
      {!bare && <rect width="256" height="256" rx="58" fill={"url(#" + uid + "-bg)"}></rect>}
      {!bare && <rect width="256" height="256" rx="58" fill={"url(#" + uid + "-gl)"}></rect>}
      {ZS_NAMI_WAVES.map(([d, c, thin, thick], i) => (
        <path key={i} d={d} stroke={c} strokeWidth={heavy ? thick : thin} fill="none" strokeLinecap="round" strokeLinejoin="round"></path>
      ))}
    </svg>
  );
  return chip ? <span className="zs-mark-chip" style={{ borderRadius: size * 0.2266 }}>{svg}</span> : svg;
}
