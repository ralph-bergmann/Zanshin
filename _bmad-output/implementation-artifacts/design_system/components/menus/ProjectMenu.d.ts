import * as React from "react";

export interface RecentProject { id: string; name: string; branch?: string; path?: string; status?: string; }
/** Menu under the project capsule: recent projects, All Projects…, Project Settings…, Settings… ⌘, States: as Menu — the open project checked; Project Settings… disabled without a project · closing. */
export interface ProjectMenuProps {
  /** up to 5, the open one first */
  recent: RecentProject[];
  activeId?: string;
  onPick?: (p: RecentProject) => void;
  onAll?: () => void;
  onProjectSettings?: () => void;
  onSettings?: () => void;
  /** take keyboard focus on open */
  autoFocus?: boolean;
  /** Esc / ← — return focus to the capsule */
  onClose?: () => void;
  /** play the exit (--dur-exit) */
  closing?: boolean;
  className?: string;
  style?: React.CSSProperties;
}
export declare function ProjectMenu(props: ProjectMenuProps): JSX.Element;
