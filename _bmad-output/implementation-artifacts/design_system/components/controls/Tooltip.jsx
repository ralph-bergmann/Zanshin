import React from "react";
import { zsMs } from "../menus/Menu.jsx";

let zsTipWarmUntil = 0;
const ZS_FLIP = { bottom: "top", top: "bottom", right: "left", left: "right" };

// Tooltip — replaces the HTML title on controls. After --delay-tooltip (700ms) of rest; at once while "warm" (another tooltip closed
// less than --dur-tooltip-warm ago). Verbs first, jj underneath: label (+ shortcut, plain text) on the first line, the exact command under it.
// Placement: 8px from the control; when it would leave the window it FLIPS to the other side, then CLAMPS 8px inside the edges
// (shifted along its axis, the arrowless box never covers the control). Hides on leave (--dur-exit fade) and on press.
// Keyboard focus shows it after the same delay; it is the control's description for VoiceOver (aria-describedby) while shown.
// A disabled control with a reason: wrap it — the anchor keeps the hover while the control takes none (base.css › disabled).
export function Tooltip({ label, cmd, shortcut, placement = "bottom", open, delay, children, className = "" }) {
  const [show, setShow] = React.useState(false);
  const [closing, setClosing] = React.useState(false);
  const [fit, setFit] = React.useState({ side: placement, dx: 0, dy: 0, done: false });
  const t = React.useRef(0), tip = React.useRef(null);
  const id = React.useId();
  React.useEffect(() => () => clearTimeout(t.current), []);
  const enter = () => {
    clearTimeout(t.current);
    t.current = setTimeout(() => { setClosing(false); setFit({ side: placement, dx: 0, dy: 0, done: false }); setShow(true); }, Date.now() < zsTipWarmUntil ? 0 : delay != null ? delay : zsMs("--delay-tooltip", 700));
  };
  const leave = () => {
    clearTimeout(t.current);
    if (!show) return;
    zsTipWarmUntil = Date.now() + zsMs("--dur-tooltip-warm", 600);
    setClosing(true);
    t.current = setTimeout(() => { setShow(false); setClosing(false); }, zsMs("--dur-exit", 120));
  };
  const visible = open != null ? open : show;
  // measure once per showing: flip if the preferred side has no room, then clamp along the other axis
  React.useLayoutEffect(() => {
    const el = tip.current; if (!visible || !el || fit.done) return;
    const r = el.getBoundingClientRect(), W = window.innerWidth, H = window.innerHeight, m = 8;
    let side = fit.side;
    const out = { bottom: r.bottom > H - m, top: r.top < m, right: r.right > W - m, left: r.left < m };
    if (out[side] && side === placement) { setFit({ side: ZS_FLIP[side], dx: 0, dy: 0, done: false }); return; }
    const vertical = side === "bottom" || side === "top";
    const dx = vertical ? (r.left < m ? m - r.left : r.right > W - m ? W - m - r.right : 0) : 0;
    const dy = vertical ? 0 : (r.top < m ? m - r.top : r.bottom > H - m ? H - m - r.bottom : 0);
    setFit({ side, dx, dy, done: true });
  }, [visible, fit]);
  return (
    <span className={("zs-tip-anchor " + className).trim()} onMouseEnter={enter} onMouseLeave={leave} onPointerDown={leave}
      onFocus={(e) => { try { if (e.target.matches(":focus-visible")) enter(); } catch (_) {} }} onBlur={leave} aria-describedby={visible ? id : undefined}>
      {children}
      {visible && (
        <span ref={tip} id={id} role="tooltip" className={["zs-tip", "is-" + fit.side, closing && "is-closing"].filter(Boolean).join(" ")}
          style={{ "--tip-dx": fit.dx + "px", "--tip-dy": fit.dy + "px" }}>
          <span className="zs-tip-l"><span>{label}</span>{shortcut && <span className="zs-tip-k">{shortcut}</span>}</span>
          {cmd && <code className="zs-tip-cmd">{cmd}</code>}
        </span>
      )}
    </span>
  );
}
