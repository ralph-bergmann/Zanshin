import * as React from "react";

/** On/off switch (30 × 18). */
export interface SwitchProps { checked?: boolean; onChange?: (checked: boolean) => void; label?: string; disabled?: boolean; }
export declare function Switch(props: SwitchProps): JSX.Element;
