import * as React from "react";

/** On/off switch (30 × 18). States: off · on · hover (edge --edge-hov · on: --fill-on-hover) · pressed (knob 12 → 15) · focus-visible · disabled. */
export interface SwitchProps { checked?: boolean; onChange?: (checked: boolean) => void; label?: string; disabled?: boolean; }
export declare function Switch(props: SwitchProps): JSX.Element;
