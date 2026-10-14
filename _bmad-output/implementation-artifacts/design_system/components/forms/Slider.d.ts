import * as React from "react";

/** Range slider with mono value readout. */
export interface SliderProps { value: number; min?: number; max?: number; step?: number; onChange?: (v: number) => void; width?: number; unit?: string; label?: string; showValue?: boolean; }
export declare function Slider(props: SliderProps): JSX.Element;
