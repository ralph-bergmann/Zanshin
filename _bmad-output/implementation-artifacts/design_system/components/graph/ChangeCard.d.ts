import * as React from "react";

/**
 * One jj change in the graph.
 */
export interface ChangeCardProps extends React.HTMLAttributes<HTMLDivElement> {
  id: string;
  /** first line of the description; omit for "(no description set)" */
  subject?: string;
  author?: string;
  /** relative time: "now", "3h", "Sep 19" */
  date?: string;
  bookmarks?: string[];
  workingCopy?: boolean;
  selected?: boolean;
  hover?: boolean;
  immutable?: boolean;
  empty?: boolean;
  root?: boolean;
  conflict?: boolean;
  merge?: boolean;
  /** 62px two-line (default) vs 40px one-line */
  detailed?: boolean;
  width?: number;
  dim?: boolean;
  /** highlighted as a rebase drop target */
  drop?: boolean;
  /** "src" = the card being dragged (faded) · "from" = the change a file/hunk/bookmark is dragged out of (dashed moon border) */
  dragging?: "src" | "from";
  /** moon pulse after an operation touched this change */
  flash?: boolean;
  /** its ••• menu is open */
  menuOpen?: boolean;
  /** shows the ••• button on the bottom edge (hover / focus) */
  onMenu?: (e: React.MouseEvent) => void;
  /** shows a round bookmark button on the top edge when the change has no bookmark */
  onBookmark?: (e: React.MouseEvent) => void;
  /** extra absolutely-positioned layers (e.g. a PeekCard) */
  children?: React.ReactNode;
}
export declare function ChangeCard(props: ChangeCardProps): JSX.Element;
