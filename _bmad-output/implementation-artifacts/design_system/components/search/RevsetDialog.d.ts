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

/** "jj log Configurations" — built-ins + custom configurations, each can be the default search. 880 × 580. */
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
  /** "12 of 35 changes match" under the command */
  matchCount?: number;
  total?: number;
  /** enables Apply */
  dirty?: boolean;
  /** wrap in the modal scrim (rgba(7,9,20,.48), blur 12px — as Settings / Projects); Esc and a click outside call onClose */
  overlay?: boolean;
  docHref?: string;
  onSelect?: (id: string | null) => void;
  /** the Default search switch: on → this entry, off → "default" */
  onDefaultChange?: (id: string) => void;
  /** name, filters, combine, add / remove / duplicate / reorder */
  onChange?: (configs: RevsetConfig[]) => void;
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
