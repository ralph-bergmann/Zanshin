import * as React from "react";

export interface ImmutableConfig {
  /** builtin_immutable_heads() = these four (all on = jj's default) */
  trunk?: boolean;
  tags?: boolean;
  remoteBookmarks?: boolean;
  remoteTags?: boolean;
  /** (trunk().. & ~mine()) — other people's changes */
  others?: boolean;
  /** bookmarks never rewritten (release or shared branches) */
  bookmarks?: string[];
  /** any revset, joined with | */
  custom?: string;
}
/** Settings › Project › Immutable commits — a SettingsPage. States: jj's default (no Reset) · changed (Reset to jj's default) · custom terms the preview can't evaluate (listed) · adding a bookmark (menu open) · every bookmark in (the add chip disabled with its reason). */
export interface ImmutablePageProps {
  config: ImmutableConfig;
  /** every change applies at once — the app writes the TOML and re-hatches the graph */
  onChange?: (config: ImmutableConfig) => void;
  /** revset-aliases."trunk()" (Settings › Project › History › Trunk) — default "main" */
  trunkName?: string;
  /** the back button's label: the Project tab's name */
  project?: string;
  onBack?: () => void;
  /** what matches here, named in the hints */
  tags?: string[];
  remoteBookmarks?: string[];
  remoteTags?: string[];
  /** the bookmarks "Bookmark…" offers (the trunk and chosen ones are left out) */
  bookmarks?: string[];
  /** changes the set makes immutable (root() not counted) — the Result line; omit to hide it */
  count?: number;
  /** the heads by name for the Result line ("main · v1.0.0 · 2 changes by others") */
  heads?: string[];
  /** custom terms the app couldn't preview */
  unknown?: string[];
  className?: string;
}
export declare function ImmutablePage(props: ImmutablePageProps): JSX.Element & {};
export declare namespace ImmutablePage {
  const defaults: Required<ImmutableConfig>;
  const builtins: { key: keyof ImmutableConfig; fn: string; name: string }[];
  /** the revset written to immutable_heads() — "builtin_immutable_heads()" for the default, "none()" for nothing */
  function expr(config: ImmutableConfig): string;
  function isDefault(config: ImmutableConfig): boolean;
  /** the set in words, for the navigation row's hint ("jj’s default (trunk, tags, remote bookmarks you don’t track)") */
  function summary(config: ImmutableConfig): string;
  /** the [revset-aliases] block exactly as written to .jj/repo/config.toml */
  function toml(config: ImmutableConfig, trunkName?: string): string;
}
