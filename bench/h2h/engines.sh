#!/bin/bash
# Engine table, single source of truth for pass.sh (sourced) and summarize.sh (`engines.sh table`). bash 3.2 safe (no assoc arrays).
# engine_spec ENGINE  sets: PORT MODEL MTP PCACHE CACHE_REPORT GUARD_DOC FLAGS_DOC PROC_PAT HEALTH_ID START_TMO CELL_TMO GUARD_PAT
#                           STUB_PF STUB_DEC STUB_CACHE   (ROOT, STRIM, D, H2H_SCRATCH are read by engine_cmd)
# engine_cmd          sets: CMD (array) and runs engine_prepare (fresh scratch HOME / model dir for oMLX).
# Ports are distinct per engine so a straggler from one engine can never be mistaken for the next one's server; strim, rapid-mlx and
# mlx-vlm keep the ports of the earlier runs. Override with H2H_PORT.
ENGINES_ALL="strim rapid-mlx mlx-vlm mlx-lm omlx"
OOM_PAT='Insufficient Memory|OutOfMemory|MemoryError|out of memory|Hard memory pressure|process memory limit exceeded|memory guard'
engine_spec() {
  START_TMO=240; CELL_TMO=${CELL_TIMEOUT:-900}; HEALTH_ID=""; GUARD_PAT="$OOM_PAT"; STUB_CACHE=1; STUB_PF=200000; STUB_DEC=2000
  case $1 in
   strim) PORT=8203; MODEL=qwen38-4bit; MTP="yes (qwen38-mtp-4bit head)"; PCACHE="yes, default (STRIM_PREFIX_CACHE_MB 12288)"
     CACHE_REPORT="usage.prompt_tokens_details.cached_tokens"; GUARD_DOC="none (admission control, max_inflight 8)"
     FLAGS_DOC="serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth"
     PROC_PAT='strim serve models/qwen38'; STUB_DEC=3000;;
   rapid-mlx) PORT=8651; MODEL=models/qwen38-4bit; MTP="yes (--speculative-config mtp, qwen38-mtp-4bit)"; PCACHE="yes, default on"
     CACHE_REPORT="not reported in usage (unknown)"; GUARD_DOC="none"
     FLAGS_DOC="--no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config {mtp,qwen38-mtp-4bit}"
     PROC_PAT='rapid-mlx --no-telemetry serve|rapid_mlx\.'; STUB_CACHE=0; STUB_DEC=2200;;
   mlx-vlm) PORT=8651; MODEL=$ROOT/models/qwen38-4bit; MTP="no"; PCACHE="no cross-request reuse (0% cached in replay)"
     CACHE_REPORT="none"; GUARD_DOC="none"
     FLAGS_DOC="--model models/qwen38-4bit --port 8651 (server defaults)"
     PROC_PAT='mlx_vlm\.server|mlx_vlm/server'; STUB_CACHE=0; STUB_DEC=1500;;
   mlx-lm) PORT=8654; MODEL=models/qwen38-4bit; MTP="no (no speculative decoding)"; PCACHE="yes, default in-memory LRU prompt cache"
     CACHE_REPORT="usage.prompt_tokens_details.cached_tokens; server log 'Prompt Cache: N sequences, X GB'"; GUARD_DOC="none"
     FLAGS_DOC="--model models/qwen38-4bit --port 8654 --decode-concurrency 4 --prompt-concurrency 4"
     PROC_PAT='mlx_lm\.server|mlx_lm/server'; STUB_DEC=1500;;
   omlx) PORT=8653; MODEL=qwen38-4bit; MTP="no (MTP needs oMLX's own checkpoint; stock weights have no MTP head)"
     PCACHE="yes, default paged SSD prefix cache under the scratch HOME (fresh per session, so no cross-session hits)"
     CACHE_REPORT="usage.prompt_tokens_details.cached_tokens (reported after warm-up; first rows can be unknown)"
     GUARD_DOC="process memory enforcer (tier balanced, ceiling ~54-56 GB): aborts requests and unloads the model"
     FLAGS_DOC="serve --model-dir <scratch>/models (symlink to models/qwen38-4bit) --port 8653, HOME=<scratch>/home, defaults otherwise (memory-guard balanced, max-concurrent-requests 8)"
     PROC_PAT='omlx-cli|oMLX\.app/Contents|omlx serve'; HEALTH_ID=qwen38-4bit; START_TMO=300; CELL_TMO=${CELL_TIMEOUT:-1200}
     GUARD_PAT="$OOM_PAT"; STUB_DEC=1400;;
   *) return 1;;
  esac
  [ -n "${H2H_PORT:-}" ] && PORT=$H2H_PORT
  local u; u=$(echo "$1" | tr 'a-z-' 'A-Z_')
  eval "[ -n \"\${H2H_CELL_TIMEOUT_$u:-}\" ] && CELL_TMO=\$H2H_CELL_TIMEOUT_$u; [ -n \"\${H2H_START_TIMEOUT_$u:-}\" ] && START_TMO=\$H2H_START_TIMEOUT_$u"
  [ "${H2H_DRYRUN:-0}" = 1 ] && PROC_PAT="$PROC_PAT|h2h-stub"
  return 0
}
engine_prepare() { # fresh per-session state; only oMLX has any
  case $E in
   omlx) OMLX_SCR=${H2H_SCRATCH:-/private/tmp/h2h-scratch}/omlx-$P-$$-$(date +%s)
     mkdir -p "$OMLX_SCR/home" "$OMLX_SCR/models" && ln -s "$ROOT/models/qwen38-4bit" "$OMLX_SCR/models/qwen38-4bit"
     echo "$OMLX_SCR" > "$D/omlx-scratch.path";;
  esac
}
engine_cleanup() { # remove only the scratch tree this session created (path recorded under its own prefix)
  case ${OMLX_SCR:-} in "${H2H_SCRATCH:-/private/tmp/h2h-scratch}"/omlx-*) rm -rf "$OMLX_SCR";; esac
}
engine_cmd() {
  if [ "${H2H_DRYRUN:-0}" = 1 ]; then
    CMD=(env STUB_PF=$STUB_PF STUB_DEC=$STUB_DEC STUB_CACHE=$STUB_CACHE STUB_MODEL=${HEALTH_ID:-$MODEL}
         STUB_HELPER=$([ "$E" = omlx ] && echo 1 || echo 0) STUB_ORPHAN=${H2H_STUB_ORPHAN_ENGINE:+$([ "$H2H_STUB_ORPHAN_ENGINE" = "$E" ] && echo 1 || echo 0)}
         STUB_GUARD_AT=$([ "$E" = "${H2H_STUB_GUARD_ENGINE:-none}" ] && echo 4 || echo 0)
         STUB_HANG=$([ "$E" = "${H2H_STUB_HANG_ENGINE:-none}" ] && echo 1 || echo 0)
         "$STUB_BIN" --port "$PORT" --engine "$E")
    return
  fi
  engine_prepare
  case $E in
   strim) CMD=("$STRIM" serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth);;
   rapid-mlx) CMD=(rapid-mlx --no-telemetry serve models/qwen38-4bit --port $PORT --max-num-seqs 4 --speculative-config '{"method":"mtp","model":"models/qwen38-mtp-4bit"}');;
   mlx-vlm) CMD=("${MLXVLM_BIN:-$ROOT/.venv-sprint/bin/mlx_vlm.server}" --model "$ROOT/models/qwen38-4bit" --port $PORT);;
   mlx-lm) CMD=("${MLXLM_BIN:-$ROOT/.venv-sprint/bin/mlx_lm.server}" --model models/qwen38-4bit --port $PORT --decode-concurrency 4 --prompt-concurrency 4);;
   omlx) CMD=(env HOME="$OMLX_SCR/home" "${OMLX_BIN:-omlx}" serve --model-dir "$OMLX_SCR/models" --port $PORT);;
  esac
}
engine_version() { # one line, no python
  local sp; sp=$(ls -d "$ROOT"/.venv-sprint/lib/python*/site-packages 2>/dev/null | head -1)
  case $1 in
   strim) "$STRIM" --version 2>&1 | head -1;;
   rapid-mlx) rapid-mlx --version 2>&1 | head -1;;
   mlx-vlm) ls "$sp" 2>/dev/null | sed -n 's/^mlx_vlm-\(.*\)\.dist-info$/mlx-vlm \1/p' | head -1;;
   mlx-lm) ls "$sp" 2>/dev/null | sed -n 's/^mlx_lm-\(.*\)\.dist-info$/mlx-lm \1/p' | head -1;;
   omlx) echo "oMLX $("${OMLX_BIN:-omlx}" --version 2>&1 | head -1)";;
  esac
}
if [ "${1:-}" = table ]; then # engines.sh table [ENGINE,ENGINE...] [RESULTS_DIR]  -> markdown (used by summarize.sh)
  ROOT=${H2H_ROOT:-.}; ENGL=${2:-${ENGINES_ALL// /,}}; RD=${3:-}
  echo '| engine | version (measured) | MTP / speculative | prefix cache | cache hits visible via | own memory guard | flags (cwd = repo root) |'
  echo '|---|---|---|---|---|---|---|'
  for e in ${ENGL//,/ }; do
    engine_spec "$e" || continue
    v=$(cat "$RD/$e"/pass*/versions.txt 2>/dev/null | grep -v '^$' | sort -u | head -1); echo "| $e | ${v:-n/a} | $MTP | $PCACHE | $CACHE_REPORT | $GUARD_DOC | \`$FLAGS_DOC\` |"
  done
fi
if [ "${1:-}" = tsv ]; then # engines.sh tsv ENGINES RESULTS_DIR -> engine<TAB>port<TAB>mtp<TAB>prefix_cache<TAB>cache_report<TAB>guard<TAB>flags<TAB>version<TAB>model
  ROOT=${H2H_ROOT:-.}; ENGL=${2:-${ENGINES_ALL// /,}}; RD=${3:-}
  for e in ${ENGL//,/ }; do
    engine_spec "$e" || continue
    v=$(cat "$RD/$e"/pass*/versions.txt 2>/dev/null | grep -v '^$' | sort -u | head -1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$PORT" "$MTP" "$PCACHE" "$CACHE_REPORT" "$GUARD_DOC" "$FLAGS_DOC" "${v:-n/a}" "${HEALTH_ID:-$MODEL}"
  done
fi
