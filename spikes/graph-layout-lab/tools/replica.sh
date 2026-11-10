#!/bin/zsh
# Builds the layout input of one repository for the lab: data/<name>.json and data/<name>.meta.json.
# It reads the repository with git only. jj runs on an empty-commit copy under data/, never in the
# repository itself.
#
# usage: tools/replica.sh <git repository> <name> [--subjects]
#   --subjects  keep each commit's subject, author name and the ref names (own and public
#               repositories). Without it the copy holds no content (client repositories).
set -e
L=${0:A:h:h}
Z=${L:h:h}
G=$Z/spikes/graph-layout-ab/rust-inputs/target/release/gen-inputs
repo=$1
name=$2
if [[ -z $repo || ! $name =~ '^[A-Za-z0-9_-]+$' ]]; then
  echo "usage: tools/replica.sh <git repository> <name> [--subjects]" >&2
  exit 2
fi
if [[ ! -x $G ]]; then
  echo "Build the dumper first: cargo build --release --manifest-path $Z/spikes/graph-layout-ab/rust-inputs/Cargo.toml" >&2
  exit 2
fi
W=$L/data/.work-$name
rm -rf "$W"
mkdir -p "$W"
git -C "$repo" log --branches --remotes --tags --topo-order \
  --format='%H%x1f%ct%x1f%at%x1f%P%x1f%an%x1f%s' --output="$W/log.txt"
git -C "$repo" for-each-ref --format='%(objectname) %(*objectname) %(refname)' \
  refs/heads refs/remotes refs/tags > "$W/refs.txt"
python3 -I "$L/tools/make_replica.py" "$W/log.txt" "$W/refs.txt" "$(git -C "$repo" rev-parse HEAD)" "$W/stream" $3
git init -q -b head "$W/repo"
git -C "$W/repo" fast-import --quiet --force < "$W/stream"
JJ_CONFIG=$L/tools/jjconfig.toml jj git init --colocate "$W/repo" > /dev/null 2>&1
JJ_CONFIG=$L/tools/jjconfig.toml "$G" dump --repo "$W/repo" --revset 'all()' --out "$L/data/$name.json"
rm -rf "$W"
