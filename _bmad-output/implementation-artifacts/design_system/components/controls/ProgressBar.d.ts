/** 4px progress bar. Determinate with value; indeterminate without. States: determinate (--accent-line on --progress-track, value on --dur-expand) · indeterminate (sweep; Reduce motion: full and pulsing). */
export interface ProgressBarProps {
  value?: number;
  max?: number;
  label?: string;
  width?: number | string;
  className?: string;
  style?: any;
}
export declare function ProgressBar(props: ProgressBarProps): JSX.Element;
