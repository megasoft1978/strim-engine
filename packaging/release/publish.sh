#!/usr/bin/env bash
set -euo pipefail
mode=dry-run
message_file=
while (($#)); do
  case "$1" in
    --push) mode=push; shift ;;
    --message-file) [[ $# -ge 2 ]] || { echo '--message-file requires a path' >&2; exit 2; }; message_file=$2; shift 2 ;;
    *) echo "usage: $0 [--push] --message-file <file>" >&2; exit 2 ;;
  esac
done
[[ -n "$message_file" && -f "$message_file" ]] || { echo "message file required" >&2; exit 2; }
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/strim-publish.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
clone="$scratch/clone"
tree="$scratch/tree"
git clone --quiet --branch main --single-branch https://github.com/megasoft1978/strim-engine "$clone"
"$repo/packaging/release/publish-tree.sh" "$tree"
"$repo/packaging/release/leak-scan.sh" "$tree"
rsync -a --delete --exclude=.git/ "$tree/" "$clone/"
git -C "$clone" diff --stat
if [[ "$mode" == push ]]; then
  before=$(git -C "$clone" rev-parse origin/main)
  git -C "$clone" add -A
  if git -C "$clone" diff --cached --quiet; then echo 'nothing to publish'; exit 0; fi
  git -C "$clone" -c user.name='Gabriele Ferreri' -c user.email='megasoft78@gmail.com' commit -F "$message_file"
  git -C "$clone" fetch origin main
  [[ "$(git -C "$clone" rev-parse origin/main)" == "$before" ]] || { echo 'remote main moved during publish; aborting' >&2; exit 1; }
  git -C "$clone" push origin HEAD:main
else
  echo 'dry run only; no commit or push performed'
fi
