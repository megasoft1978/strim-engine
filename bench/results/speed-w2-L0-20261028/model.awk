# usage: awk -v fence_us=F -v kappa=K -f model.awk full.txt sweep1.txt sweep2.txt ...
# Reads the full-fence report rows ("| ctx | name | calls | raw | ...") and SWEEP lines; prints per-name corrected net.
BEGIN { FS = "[ ]*\\|[ ]*" }
FNR == 1 { fidx++ }
/^SWEEP / && $0 !~ /SWEEP_HEADER/ && $0 !~ /^SWEEP n=/ { split($0, a, " "); n = a[2]; sc[n] = a[3]; sraw[n] = a[4]; swx[n] = a[5]; swb[n] = a[6]; nb++; bsum += a[6]; next }
fidx == 1 && /^\| (main|mtp) \|/ { nm = $3; if (nm == "mtp_other") { other += $5; othercalls += $4; next } calls[nm] += $4; raw[nm] += $5; if (!(nm in seen)) { seen[nm] = 1; ord[++no] = nm } }
END {
  f = fence_us / 1000.0; plain = bsum / nb; totraw = 0; totcalls = 0
  for (i = 1; i <= no; i++) { nm = ord[i]; totraw += raw[nm]; totcalls += calls[nm] }
  totraw += other; totcalls += othercalls
  # s_i: per-call wall extra when only this name is fenced
  den = 0
  for (i = 1; i <= no; i++) { nm = ord[i]; if (nm in swx) { s[nm] = (swx[nm] - swb[nm]) / sc[nm]; den += calls[nm] * (s[nm] - f) } }
  printf "plain_wall_ms=%.1f  sum_raw=%.1f  calls=%d  fence_cal_us=%d\n", plain, totraw, totcalls, fence_us
  printf "%-16s %6s %9s %7s %9s %9s %9s\n", "name", "calls", "raw_ms", "s_ms", "upper", "lower", "model"
  su = 0; sl = 0; sm = 0
  for (i = 1; i <= no; i++) {
    nm = ord[i]; c = calls[nm]; si = (nm in s) ? s[nm] : f
    up = raw[nm] - c * f; lo = raw[nm] - c * si; if (lo < 0) lo = 0
    md = raw[nm] - c * (f + kappa * (si - f)); if (md < 0) md = 0
    su += up; sl += lo; sm += md
    printf "%-16s %6d %9.1f %7.3f %9.1f %9.1f %9.1f\n", nm, c, raw[nm], si, up, lo, md
  }
  up = other - othercalls * f; su += up; sl += other - othercalls*0.5; sm += up
  printf "%-16s %6d %9.1f %7s %9.1f %9.1f %9.1f\n", "mtp_other", othercalls, other, "-", up, up, up
  printf "SUM upper=%.1f (%+.1f%%) lower=%.1f (%+.1f%%) model=%.1f (%+.1f%%) vs plain %.1f\n", su, (su-plain)/plain*100, sl, (sl-plain)/plain*100, sm, (sm-plain)/plain*100, plain
  printf "kappa_fit_for_exact=%.3f\n", (totraw - plain - totcalls * f) / den
}
