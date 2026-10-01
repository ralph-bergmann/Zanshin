// The design export the spike's design sample, its oracle (docs/graph-layout.md §7.2) and the SPEC's
// expectations were derived from: 57f259c, 22 commits. Ralph replaces the export folder wholesale
// on every re-download (36 commits since a399daf, 52 since e243dd2, where computeLayout also calls
// graph-gaps.jsx), so the tools read this revision from git, never the working tree.

import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

export const DESIGN_REV = "57f259cf203d0165b83ba1f4b52a958b4f51bcd8";

/** One file of the design export at `commit` (default: the pinned export), read with `git show`. */
export function designFile(name, commit = DESIGN_REV) {
  return execFileSync("git", ["-C", repo, "show", `${commit}:_bmad-output/implementation-artifacts/design/${name}`], { encoding: "utf8" });
}
