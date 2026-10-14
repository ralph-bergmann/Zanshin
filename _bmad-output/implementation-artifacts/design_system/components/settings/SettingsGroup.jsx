import React from "react";

// SettingsGroup — caps heading over one rounded box of rows (settings window). Group by what the user is deciding, not by config file.
export function SettingsGroup({ title, children, className = "" }) {
  return (
    <section className={("zs-setgrp " + className).trim()}>
      {title && <h3 className="zs-setgrp-h">{title}</h3>}
      <div className="zs-setbox">{children}</div>
    </section>
  );
}
