import * as React from "react";

/** macOS window buttons (a mock — the app shows the system's). States: rest (grey rings) · group hover (system colours + symbols; disabled ones greyed) · pressed (darker) · disabled (per button) · inactive window (rings, as at rest). */
export interface TrafficLightsProps {
  /** which buttons are enabled — project window: all · Projects: close + zoom · Settings: close */
  buttons?: { close?: boolean; minimize?: boolean; zoom?: boolean };
  /** force the hover look (specimens) */
  hover?: boolean;
  onClose?: () => void;
  onMinimize?: () => void;
  onZoom?: () => void;
  className?: string;
  style?: React.CSSProperties;
}
export declare function TrafficLights(props: TrafficLightsProps): JSX.Element;
