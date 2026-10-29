#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -d "$1" ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
root=$(cd "$1" && pwd)
script_dir=$(cd "$(dirname "$0")" && pwd)
allow="$script_dir/leak-allow.txt"
failed=0
# Construct markers in pieces so the scanner does not flag its own rule definitions.
home=$(printf '/Users/%s' 'megasoft78')
encoded=$(printf '%s-%s-%s' '' 'Users' 'megasoft78')
pat_home="${home}|${encoded}"
pat_gab=$(printf 'gabrie%s' 'les')
pat_ip='192\.168\.[0-9]'
pat_pat="$(printf 'github_%s' 'pat_')"
pat_gh='gh[posur]_[A-Za-z0-9]{20,}'
pat_anthropic="$(printf 'sk-%s' 'ant-')[A-Za-z0-9_-]{20,}"
pat_hf="$(printf 'hf_%s' '[A-Za-z0-9]{20,}')"
pat_aws="$(printf 'AK%s' 'IA')"
pat_key='BEGIN (RSA|OPENSSH|PRIVATE)'
names=(HOME_PATH GABRIELES PRIVATE_IP GITHUB_PAT GITHUB_TOKEN ANTHROPIC_TOKEN HUGGINGFACE_TOKEN AWS_KEY PRIVATE_KEY)
regexes=("$pat_home" "$pat_gab" "$pat_ip" "$pat_pat" "$pat_gh" "$pat_anthropic" "$pat_hf" "$pat_aws" "$pat_key")
combined="$pat_home|$pat_gab|$pat_ip|$pat_pat|$pat_gh|$pat_anthropic|$pat_hf|$pat_aws|$pat_key"
is_allowed() {
  local path=$1 name=$2 rule rp rn
  while IFS= read -r rule; do
    [[ -z "$rule" || "$rule" == \#* ]] && continue
    rp=${rule%%:*}; rn=${rule#*:}
    [[ "$rn" == "$name" || "$rn" == '*' ]] || continue
    if [[ "$rp" == 'Tests/**/Redactor*' ]]; then
      [[ "$path" == Tests/*/Redactor* ]] && return 0
    elif [[ "$path" == "$rp" ]]; then return 0
    fi
  done < "$allow"
  return 1
}
while IFS= read -r -d '' file; do
  rel=${file#"$root"/}
  grep -IqE "$combined" "$file" || continue
  for i in "${!names[@]}"; do
    name=${names[$i]}; re=${regexes[$i]}
    while IFS=: read -r lineno line; do
      [[ -n "$lineno" ]] || continue
      sample=$(printf '%s\n' "$line" | grep -oE "$re" | head -n 1 | cut -c1-8)
      masked=$(printf '%s\n' "$line" | awk -v re="$re" '{ gsub(re,"[MASKED]"); print }')
      if is_allowed "$rel" "$name"; then tag=ALLOW; class=SYNTHETIC; else tag=HIT; class=REAL-LOOKING; failed=1; fi
      printf '%s %s:%s pattern=%s match8=%s class=%s %s\n' "$tag" "$rel" "$lineno" "$name" "$sample" "$class" "$masked"
      start=$((lineno > 1 ? lineno - 1 : 1)); end=$((lineno + 1))
      awk -v a="$start" -v b="$end" -v re="$re" 'NR>=a&&NR<=b { line=$0; gsub(re,"[MASKED]",line); printf "  %s:%d:%s\n", FILENAME, NR, line }' "$file"
    done < <(grep -nE "$re" "$file" 2>/dev/null || true)
  done
done < <(find "$root" -type f -print0)
exit "$failed"
