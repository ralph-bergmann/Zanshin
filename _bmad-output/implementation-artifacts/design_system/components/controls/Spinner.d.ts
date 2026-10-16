/** Inline busy mark (12–16px). In buttons it takes the icon slot (Button busy). States: turning — always, also under Reduce motion. */
export interface SpinnerProps {
  /** px — the icon sizes: 12 (sm) · 14 (md, default) · 16 (lg) */
  size?: number;
  /** accessible name when it stands alone ("Fetching") */
  label?: string;
  className?: string;
  style?: any;
}
export declare function Spinner(props: SpinnerProps): JSX.Element;
