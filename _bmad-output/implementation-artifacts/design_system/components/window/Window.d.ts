import * as React from "react";

/** A macOS window of its own — Settings, Projects, jj log Configurations. The system draws corners, shadow and appearance; no scrim, no ✕, no entrance. States: active (key) · inactive (accent role neutral, no focus shown, title dimmed) · traffic lights per window (Settings: close only · Projects and Configurations: close + zoom). */
export interface WindowProps {
  /** the window title — Window menu and Mission Control; shown at block end + 12 unless titleHidden */
  title: string;
  /** Settings: the tabs are the header, the title (= the tab's name) is only given to the system */
  titleHidden?: boolean;
  /** false = not the key window (tokens/inactive.css) */
  active?: boolean;
  /** enabled traffic-light buttons; default { close: true } */
  buttons?: { close?: boolean; minimize?: boolean; zoom?: boolean };
  /** controls in the 52px header row, centred on the traffic lights' centre line */
  header?: React.ReactNode;
  /** "center": the header's controls sit in the middle of the window (Settings tabs) */
  headerAlign?: "start" | "center";
  /** a column that begins under the traffic lights (Projects: brand block, sections, signed-in user) */
  sidebar?: React.ReactNode;
  sidebarWidth?: number;
  width?: number | string;
  height?: number | string;
  onClose?: () => void;
  onZoom?: () => void;
  className?: string;
  style?: React.CSSProperties;
  children?: React.ReactNode;
}
export declare function Window(props: WindowProps): JSX.Element;
