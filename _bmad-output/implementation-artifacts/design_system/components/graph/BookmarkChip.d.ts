import * as React from "react";

/** Bookmark as a card legend (ticket id leads) or as a tag with its sync state. */
export interface BookmarkChipProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** full bookmark name, e.g. "feature/ZAN-412_onboarding-swipe-gestures" or "main@origin" */
  name: string;
  /** legend: number of further bookmarks on the same change (+N) */
  more?: number;
  /** tag: synced ✓ · ahead ↑n · behind ↓ · diverged ↕ · local · remote */
  state?: "synced" | "ahead" | "behind" | "local" | "remote" | "diverged";
  /** commits ahead of the remote (state "ahead") */
  ahead?: number;
  /** legend = pill on the card's top edge · tag = inspector / lists */
  variant?: "legend" | "tag";
  title?: string;
}
export declare function BookmarkChip(props: BookmarkChipProps): JSX.Element;
