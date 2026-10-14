import * as React from "react";

/** macOS window controls. */
export interface TrafficLightsProps { idle?: boolean; onClose?: () => void; onMinimize?: () => void; onZoom?: () => void; }
export declare function TrafficLights(props: TrafficLightsProps): JSX.Element;
