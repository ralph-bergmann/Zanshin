import React from "react";

// SettingsGroup — caps heading over one rounded box of rows (settings window). Group by what the user is deciding, not by config file.
// meta: a mono note beside the heading (the revset the group stands for, e.g. builtin_immutable_heads()) · bare: no box (a result well, a note).
export function SettingsGroup({ title, meta, bare = false, children, className = "" }) {
  return (
    <section className={("zs-setgrp " + className).trim()}>
      {title && <h3 className="zs-setgrp-h">{title}{meta && <code className="zs-setgrp-meta">{meta}</code>}</h3>}
      {bare ? children : <div className="zs-setbox">{children}</div>}
    </section>
  );
}
