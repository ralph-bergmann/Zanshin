/** Slider — 4px track, accent fill, 14px --thumb knob, mono readout. ←/→ step, ⇞/⇟ jump (native). States: rest · hover · dragging (halo) · focus-visible (ring around the thumb) · disabled. */
export interface SliderProps {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  onChange?: (value: number) => void;
  /** track width in px */
  width?: number;
  unit?: string;
  label?: string;
  showValue?: boolean;
  /** true = a tick per step (when ≤ 21 steps) · or the values to mark */
  ticks?: boolean | number[];
  disabled?: boolean;
  className?: string;
}
export declare function Slider(props: SliderProps): JSX.Element;
