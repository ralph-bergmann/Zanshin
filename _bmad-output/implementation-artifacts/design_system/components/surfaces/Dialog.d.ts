import * as React from "react";

/**
 * Modal SHEET on a blurred scrim, for short modal tasks — the two: ConfirmDialog, Push. Settings, Projects and jj log Configurations are Windows.
 * Esc (and ✕ / Cancel) call onClose — a click on the scrim does nothing; focus starts on initialFocus (or the first control), stays inside, returns on close (useSheetFocus).
 */
export interface DialogNavItem { id: string; label: string; icon?: string; count?: number; }
/** States: open · closing. */
export interface DialogProps {
  title: string;
  onClose?: () => void;
  /** optional left navigation (200px) */
  nav?: DialogNavItem[];
  activeNav?: string;
  onNav?: (id: string) => void;
  /** top of the nav column (Projects: mark + "Zanshin" + "jj client · v0.24.0") */
  navHeader?: React.ReactNode;
  /** pinned to the bottom of the nav column (signed-in user) */
  navFooter?: React.ReactNode;
  /** toolbar row under the title (search + actions) */
  tools?: React.ReactNode;
  /** default 900 × 640 (the client: min(900px, 92vw) × min(640px, 88vh)) */
  width?: number | string;
  height?: number | string;
  /** render the scrim (fills the positioned parent) */
  scrim?: boolean;
  /** play the exit (scrim fade + sheet drop, --dur-exit-lg) */
  closing?: boolean;
  /** selector of the control that gets focus on open */
  initialFocus?: string;
  className?: string;
  children?: React.ReactNode;
}
export declare function Dialog(props: DialogProps): JSX.Element;
