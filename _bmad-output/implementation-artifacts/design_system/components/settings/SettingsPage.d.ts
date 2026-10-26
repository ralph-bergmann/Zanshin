import * as React from "react";

/** A page inside a Settings tab: back button (the tab's name), title, one sentence, then SettingsGroups. States: none of its own; the back button: rest · hover · pressed · focus-visible. */
export interface SettingsPageProps {
  /** the back button's label — the tab it returns to ("MyApp") */
  back: React.ReactNode;
  onBack?: () => void;
  title: React.ReactNode;
  /** one sentence on what the page decides */
  intro?: React.ReactNode;
  className?: string;
  children?: React.ReactNode;
}
export declare function SettingsPage(props: SettingsPageProps): JSX.Element;
