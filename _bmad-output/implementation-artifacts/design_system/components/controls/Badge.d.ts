/** Count badge: 15px pill, mono 9.5/700, tabular. accent (act on it) or neutral. States: hidden (0) · in · count change (rolls in) · out · dot · accent (with its --accent-line edge) / neutral. */
export interface BadgeProps {
  /** number, text, or true for a dot; 0 / null hides it */
  count?: number | string | boolean | null;
  /** above this shows "max+" (default 99) */
  max?: number;
  tone?: "accent" | "neutral";
  label?: string;
  className?: string;
}
export declare function Badge(props: BadgeProps): JSX.Element;
