/** Pending placeholder: bar · card (240 × 62 change card) · row (30px file/project row). States: waiting (after --delay-skeleton) · sweeping; Reduce motion: pulsing. */
export interface SkeletonProps {
  kind?: "bar" | "card" | "row";
  width?: number | string;
  height?: number;
  radius?: number;
  className?: string;
  style?: any;
}
export declare function Skeleton(props: SkeletonProps): JSX.Element;
