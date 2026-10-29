# Shared CLI layout (sourced by make-release.sh and packaging/app/make-app.sh). Single source of truth.
# The real `strim` binary must sit next to its SwiftPM resource bundles: MLX finds default.metallib and the
# harness finds its prompt pack relative to the binary's own (unresolved) path.
#   tarball: strim-<v>/libexec/{strim,<bundles>}      app: Strim.app/Contents/Resources/{strim,<bundles>}
STRIM_RESOURCE_BUNDLES=(mlx-swift_Cmlx.bundle Strim_StrimHarness.bundle)

# strim_check_build <build-dir>: validates the executable, arm64, bundles and metallib.
strim_check_build() {
  local build="$1" b
  [ -x "$build/strim" ] || { echo "no executable $build/strim" >&2; return 1; }
  [ "$(uname -m)" = arm64 ] || { echo "run on arm64" >&2; return 1; }
  file "$build/strim" | grep -q arm64 || { echo "binary is not arm64" >&2; return 1; }
  for b in "${STRIM_RESOURCE_BUNDLES[@]}"; do
    [ -d "$build/$b" ] || { echo "missing $build/$b" >&2; return 1; }
  done
  [ -f "$build/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ] || { echo "default.metallib missing" >&2; return 1; }
}

# strim_stage_cli <build-dir> <dest-dir>: copies the binary and its bundles into dest-dir.
strim_stage_cli() {
  local build="$1" dest="$2" b
  mkdir -p "$dest"
  cp "$build/strim" "$dest/strim"
  chmod 0755 "$dest/strim"
  for b in "${STRIM_RESOURCE_BUNDLES[@]}"; do cp -R "$build/$b" "$dest/"; done
}

# strim_version <build-dir>: "0.1.0" from `strim --version` (no GPU).
strim_version() {
  local v
  v="$("$1/strim" --version | head -n 1 | awk '{print $2}')"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) echo "$v" ;;
    *) echo "cannot parse version from 'strim --version' (got '$v')" >&2; return 1 ;;
  esac
}
