import * as React from "react";

/** The hatch swatch — names "immutable" beside the word (peek eyebrow, card-menu note row, inspector flag, Settings › Immutable commits). 12px, sits in an sm icon column. States: none — decoration; hidden from VoiceOver unless it has a title. */
export interface HatchSwatchProps {
  /** only when it stands alone (then it is an image with this label) */
  title?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function HatchSwatch(props: HatchSwatchProps): JSX.Element;
