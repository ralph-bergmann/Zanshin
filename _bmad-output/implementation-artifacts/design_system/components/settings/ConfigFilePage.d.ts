import * as React from "react";

export interface ConfigFileError {
  /** the TOML parser's message as jj gives it (jj.config_parse_error), e.g. "invalid string\nexpected `\"`, `'`" */
  message: string;
  /** the span it points at, as offsets into the text (the app converts jj's byte span) — line and column are counted from it */
  start: number;
  end: number;
}
/** Settings › General or Project › Config file — a SettingsPage; the GUI half of `jj config edit`. States: saved · edited (gold dot, Revert + Save live) · just saved (✓ Saved) · not saved — a parse error (span marked, line/column, jj's message, Show) · changed on disk while edited (notice with Reload). */
export interface ConfigFilePageProps {
  /** General → "user" (jj config edit --user), Project → "repo" (--repo) */
  scope?: "user" | "repo";
  /** the file configFileRead returned */
  path: string;
  /** the file's saved text */
  text: string;
  /** the back button's label: the tab's name */
  back: string;
  /** the project's name (the intro of the repo scope) */
  project?: string;
  onBack?: () => void;
  /** configFileWrite: null when written, else the parse error (nothing was written) */
  onSave?: (text: string) => null | { error: ConfigFileError };
  /** the file on disk replaces the draft (after stale) */
  onReload?: () => void;
  /** the window asks before Back, another tab or closing while true (ConfirmDialog "Discard your edits to config.toml?") */
  onDirtyChange?: (dirty: boolean) => void;
  /** the file changed on disk while the draft has edits */
  stale?: boolean;
  /** cards: start with an edited draft / an error shown */
  initialDraft?: string;
  initialError?: ConfigFileError | null;
  className?: string;
}
export declare function ConfigFilePage(props: ConfigFilePageProps): JSX.Element;
export declare namespace ConfigFilePage {
  /** 1-based line and column of a byte offset in text */
  function position(text: string, at: number): { line: number; col: number };
}
