# usage: awk -v plain=MS -v fence_us=F -f table.awk raw/gemm.txt raw/opmicro.txt raw/fullNk.txt
# Builds the reconciled per-op table: GEMM regions priced at the pipelined microbench rate of their real shape
# (M=1024), non-GEMM regions at their pipelined microbench cost (+0.136 ms for the blocked GDN kernel's input copies),
# MTP-head regions at fence-corrected raw. FLOP/bytes come from the OpTimer counts.
function interp(P,   i) { # piecewise-linear sdpa ms vs prefix
  if (P <= 0) return sd[0]
  for (i = 1; i <= 3; i++) if (P <= sp[i]) return sd[i-1] + (sd[i] - sd[i-1]) * (P - sp[i-1]) / (sp[i] - sp[i-1])
  return sd[3] + (sd[3] - sd[2]) * (P - sp[3]) / (sp[3] - sp[2])
}
FILENAME ~ /gemm/ && /^GEMM qmm4/ && $0 ~ /M=1024/ { nm = $3; for (i = 1; i <= NF; i++) if ($i == "pipelined") { g[nm] = $(i+1) } }
FILENAME ~ /opmicro/ && /^OP / { nm = $2; for (i = 1; i <= NF; i++) if ($i == "pipelined") { o[nm] = $(i+1) } }
FILENAME ~ /full/ && /^\| (main|mtp) \|/ {
  FS_ = "[ ]*\\|[ ]*"; split($0, ff, FS_); c = ff[2]; nm = ff[3]; key = c "|" nm
  calls[key] = ff[4]; raw[key] = ff[5]; gfl[key] = ff[8]; gb[key] = ff[9]
  if (!(key in seen)) { seen[key] = 1; ord[++no] = key }
}
END {
  sp[0] = 0; sp[1] = 2048; sp[2] = 8192; sp[3] = 15360
  sd[0] = o["attn.sdpa(prefix=0)"]; sd[1] = o["attn.sdpa(prefix=2048)"]; sd[2] = o["attn.sdpa(prefix=8192)"]; sd[3] = o["attn.sdpa(prefix=15360)"]
  f = fence_us / 1000
  per["main|gdn.proj"] = (g["gdn.in_proj_qkv"] + g["gdn.in_proj_z"]) / 2
  per["main|gdn.out"] = g["gdn.out_proj"]
  per["main|mlp.gateup"] = g["mlp.gateup"]; per["main|mlp.down"] = g["mlp.down"]
  per["main|attn.proj"] = (g["attn.q_proj"] + 2 * g["attn.kv_proj"]) / 3
  per["main|attn.o"] = g["attn.o_proj"]
  per["main|gdn.rec"] = o["gdn.rec"] + 0.136
  per["main|gdn.conv"] = o["gdn.conv"]; per["main|gdn.qknorm_bg"] = o["gdn.qknorm_bg"]
  per["main|gdn.norm_gate"] = o["gdn.norm_gate"]; per["main|gdn.proj_ba"] = o["gdn.proj_ba(2"]
  per["main|norm"] = o["norm"]; per["main|resid"] = o["resid"]; per["main|mlp.act"] = o["mlp.act"]
  per["main|attn.qknorm"] = o["attn.qknorm"]; per["main|attn.gate"] = o["attn.gate"]
  per["main|attn.rope_append"] = o["attn.rope(offset=0)"]
  tot = 0
  for (i = 1; i <= no; i++) {
    k = ord[i]; n = calls[k]
    if (k == "main|attn.sdpa") { nch = n / 16; e = 0; for (c = 0; c < nch; c++) e += 16 * interp(1024 * c); est[k] = e }
    else if (k in per) est[k] = n * per[k]
    else { est[k] = raw[k] - n * f; if (est[k] < 0) est[k] = 0 }
    tot += est[k]
  }
  print "| ctx | region | calls | fenced raw ms | est. ms (pipelined) | share of est. pct | GFLOP | GB | TF/s | pct of 62.7 | GB/s | pct of 530 | basis |"; print "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"
  for (i = 1; i <= no; i++) {
    k = ord[i]; split(k, kk, "|"); e = est[k]; s = e / 1000
    basis = (k in per || k == "main|attn.sdpa") ? "microbench" : "raw-fence"
    if (k == "mtp|mtp_other") basis = "raw-fence"
    tf = (gfl[k] > 0 && s > 0) ? gfl[k] / 1000 / s : 0
    bw = (s > 0) ? gb[k] / s : 0
    printf "| %s | %s | %d | %.1f | %.1f | %.1f | %.1f | %.2f | %s | %s | %.0f | %.0f | %s |\n", kk[1], kk[2], calls[k], raw[k], e, (tot > 0 ? e / tot * 100 : 0), gfl[k], gb[k], (tf > 0 ? sprintf("%.1f", tf) : "-"), (tf > 0 ? sprintf("%.0f", tf / 62.7 * 100) : "-"), bw, bw / 530 * 100, basis
  }
  printf "\nSUM est %.1f ms vs plain wall %.1f ms: %+.1f%%\n", tot, plain, (tot - plain) / plain * 100
  # group rollup
  for (i = 1; i <= no; i++) { k = ord[i]; split(k, kk, "|"); split(kk[2], pp, "."); g2 = kk[1] "/" pp[1]; gm[g2] += est[k]; if (!(g2 in gs)) { gs[g2] = 1; go[++ng] = g2 } }
  printf "\n| group | est. ms | share of plain wall %% |\n|---|---:|---:|\n"
  for (i = 1; i <= ng; i++) printf "| %s | %.1f | %.1f |\n", go[i], gm[go[i]], gm[go[i]] / plain * 100
  nong = gm["main/gdn"] - est["main|gdn.proj"] - est["main|gdn.out"]
  printf "\nGDN non-GEMM (rec+conv+qknorm_bg+norm_gate+proj_ba) %.1f ms = %.2f%% of plain wall; rec alone %.1f ms = %.2f%%\n", nong, nong / plain * 100, est["main|gdn.rec"], est["main|gdn.rec"] / plain * 100
}
