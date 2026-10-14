import * as React from "react";

/**
 * Modal sheet on a blurred scrim.
 */
export interface DialogNavItem { id: string; label: string; icon?: string; count?: number; }
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
  className?: string;
  children?: React.ReactNode;
}
export declare function Dialog(props: DialogProps): JSX.Element;
