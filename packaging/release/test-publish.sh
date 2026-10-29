#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/strim-publish-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/bench" "$repo/Tests" "$repo/Sources" "$repo/docs" "$repo/site" "$repo/packaging/release"
printf 'path=/Users/user/work\nencoded=-Users-user\n' > "$repo/bench/sample.txt"
for area in Tests Sources docs site; do
  printf 'path=/Users/user/work\nencoded=-Users-user\n' > "$repo/$area/sample.txt"
done
cp "$here/publish-tree.sh" "$repo/packaging/release/"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
git -C "$repo" add . && git -C "$repo" commit -qm fixture
out="$tmp/out"
(cd "$repo" && "$repo/packaging/release/publish-tree.sh" "$out") >/dev/null
grep -q '/Users/user/work' "$out/bench/sample.txt"
grep -q -- '-Users-user' "$out/bench/sample.txt"
for area in Tests Sources docs site; do
  grep -q '/Users/user/work' "$out/$area/sample.txt"
  grep -q -- '-Users-user' "$out/$area/sample.txt"
done
printf '%s%s\n' 'ghp_' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890' > "$out/token.txt"
if "$here/leak-scan.sh" "$out" >/dev/null 2>&1; then echo 'expected planted token failure' >&2; exit 1; fi
rm "$out/token.txt"
"$here/leak-scan.sh" "$out" >/dev/null
mkdir "$tmp/nonempty"; touch "$tmp/nonempty/keep"
if (cd "$repo" && "$repo/packaging/release/publish-tree.sh" "$tmp/nonempty") >/dev/null 2>&1; then echo 'expected non-empty destination refusal' >&2; exit 1; fi
echo 'publish fixture checks passed'
