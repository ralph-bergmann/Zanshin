import * as React from "react";

/** The suggestions popover under the graph search (540px min, the one menu material, radius 13) — a field-attached list: focus stays in the field. States: open · keyboard row (aria-activedescendant) · empty (one sentence) · closing (fade). */
export interface SearchPopoverProps extends React.HTMLAttributes<HTMLDivElement> {
  /** a line above the rows, e.g. 'No author matches “xyz” — found elsewhere:' */
  note?: React.ReactNode;
  /** shown when nothing matches, e.g. 'Nothing matches “xyz” — in any scope.' */
  empty?: React.ReactNode;
  /** what Enter does for the keyboard row: the command (Filter) or the go-to sentence (Select / Show) */
  footer?: { text: React.ReactNode; verb?: string };
  listRef?: React.Ref<HTMLDivElement>;
  /** id of the listbox (the field's aria-controls); rows are listId-<index> by convention */
  listId?: string;
  children?: React.ReactNode;
}
export declare function SearchPopover(props: SearchPopoverProps): JSX.Element;

/** Group header: small caps; quiet note (em) or action (Clear) on the right. */
export declare function SearchGroup(props: { label: React.ReactNode; note?: React.ReactNode; action?: string; onAction?: () => void }): JSX.Element;

/** One 34px suggestion row. States: rest · hover (--fl-hover) · pressed (--fl-on) · keyboard row (active: --accent-soft, icon in accent). */
export interface SearchRowProps extends Omit<React.HTMLAttributes<HTMLDivElement>, "onClick" | "onMouseMove"> {
  /** Icon name (change, bookmark, user, file, folder, description, search) or a node (SearchAvatar) */
  icon?: string | React.ReactNode;
  /** main text (or a SearchMatch) */
  label?: React.ReactNode;
  /** quoted query after the label: Descriptions containing “cache” */
  quote?: string;
  /** before the label: AtBadge + ChangeId on change rows */
  before?: React.ReactNode;
  /** after the label: SearchTag ("glob", "you · mine()") */
  after?: React.ReactNode;
  /** mono expression after the label (recent searches) */
  sub?: string;
  /** label in mono — paths */
  mono?: boolean;
  /** "(no description set)" */
  dim?: boolean;
  /** right column: counts (tabular), author · date, "not in view" */
  meta?: React.ReactNode;
  /** the keyboard row: --accent-soft, icon in accent (give it an id for the field's aria-activedescendant). Hover is --fl-hover and does not move it. */
  active?: boolean;
  /** @deprecated — use active */
  highlighted?: boolean;
  /** "3 more in Files" row — chevron on the right */
  more?: boolean;
  onClick?: React.MouseEventHandler<HTMLDivElement>;
  onMouseMove?: React.MouseEventHandler<HTMLDivElement>;
}
export declare function SearchRow(props: SearchRowProps): JSX.Element;

/** The match underlined in moon; everything before `split` dimmed (a path's folder part). match = [start, end] or the query. */
export declare function SearchMatch(props: { text: string; match?: [number, number] | string | null; split?: number }): JSX.Element;
export declare function SearchTag(props: { children?: React.ReactNode }): JSX.Element;
/** An author's initial, 18px circle. */
export declare function SearchAvatar(props: { name: string }): JSX.Element;
