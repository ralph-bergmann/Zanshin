import * as React from "react";

export interface RevsetRule {
  fn: "author" | "committer" | "mine" | "subject" | "description" | "files";
  /** text: substring · exact · glob · regex; files: prefix · file · glob */
  mode?: string;
  value?: string;
  /** case-insensitive (-i) */
  ci?: boolean;
  /** negated (~) */
  not?: boolean;
}
export interface RevsetConfig { id: string; name: string; op?: "&" | "|"; rules?: RevsetRule[]; /** used when there are no rules */ expr?: string; }

/** "jj log Configurations" — a window of its own (Window scaffold), not a sheet: built-ins + custom configurations, each can be the default search. 880 × 580 by default, resizable, min 680 × 460. States: open · entry selected · empty selection · dirty (Apply) · copied · asking ("Discard changes?") · inactive (the graph is key). */
export interface RevsetDialogProps {
  /** default: RevsetDialog.builtins (jj log, all()) */
  builtins?: Array<{ id: string; cmd: string; desc: string }>;
  configs?: RevsetConfig[];
  /** id of the selected entry (built-in or configuration); null = empty state */
  selected?: string | null;
  /** id of the default search; "default" (jj log) is the fallback */
  defaultId?: string;
  /** your name for mine() rows */
  me?: string;
  /** "12 of 35 changes match in <project>" under the command — always the project in the project window */
  matchCount?: number;
  total?: number;
  /** enables Apply */
  dirty?: boolean;
  /** the project the count, mine() and Apply / OK refer to (the one in the project window; it follows a project switch) */
  project?: string;
  /** false: not the key window (a click in the graph) — tokens/inactive.css */
  active?: boolean;
  /** the window's size — remembered with its position; resizable down to 680 × 460 (the list stays 240, the editor grows) */
  width?: number;
  height?: number;
  onZoom?: () => void;
  /** controlled "Discard changes?" (e.g. ⌘W from the menu bar); default: internal */
  discarding?: boolean;
  onDiscarding?: (asking: boolean) => void;
  docHref?: string;
  onSelect?: (id: string | null) => void;
  /** the Default search switch: on → this entry, off → "default" */
  onDefaultChange?: (id: string) => void;
  /** name, filters, combine, add / remove / duplicate / reorder */
  onChange?: (configs: RevsetConfig[]) => void;
  /** Cancel, Esc, ⌘W and the red button — after "Discard changes?" when dirty */
  onCancel?: () => void;
  onApply?: () => void;
  onOk?: () => void;
  onClose?: () => void;
  className?: string;
  style?: React.CSSProperties;
}
export declare function RevsetDialog(props: RevsetDialogProps): JSX.Element;
export declare namespace RevsetDialog {
  const builtins: Array<{ id: string; cmd: string; desc: string }>;
  /** the revset a configuration stands for, e.g. files("lib/features/onboarding/") or mine() & subject(glob:"fix*") */
  function exprOf(cfg: RevsetConfig): string;
  function ruleExpr(rule: RevsetRule): string;
}
