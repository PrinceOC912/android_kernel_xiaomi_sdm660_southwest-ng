#!/usr/bin/env bash
# Refresh the vendored SUSFS / xxksu glue patches from their upstream sources.
#
# Usage (from anywhere):
#   bash /path/to/susfs/update-vendor-patches.sh
#
# The script updates the files next to itself, so the exact same copy works
# both in the workflow source tree and, after ak-sync.sh mirrors it, at
# .github/workflows/susfs/update-vendor-patches.sh in the kernel repo.
#
# Override the sources with NGKI_RAW / MIDORI_GLUE_PATCH if needed.
# Nothing is committed, pushed, or scheduled -- review the printed diff first.

set -euo pipefail

NGKI_RAW="${NGKI_RAW:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline}"
MIDORI_GLUE_PATCH="${MIDORI_GLUE_PATCH:-https://github.com/midori01/KernelSU/commit/xx.patch}"

# Resolve from the script's own location; do not hardcode an absolute path.
TARGET="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/susfs-refresh.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

names=(
  susfs_patch_to_4.19.patch
  susfs_inline_hook_patches.sh
  xxksu-susfs.patch
)
dests=(
  "$TARGET/vendor/susfs_patch_to_4.19.patch"
  "$TARGET/vendor/susfs_inline_hook_patches.sh"
  "$TARGET/xxksu-susfs.patch"
)
urls=(
  "$NGKI_RAW/Patches/Patch/susfs_patch_to_4.19.patch"
  "$NGKI_RAW/Patches/susfs_inline_hook_patches.sh"
  "$MIDORI_GLUE_PATCH"
)

validate() {
  local name="$1" file="$2"
  case "$name" in
    susfs_patch_to_4.19.patch)
      grep -q '^diff --git a/' "$file"
      ;;
    xxksu-susfs.patch)
      # Guard against pointing MIDORI_GLUE_PATCH at an unrelated commit.
      grep -q '^diff --git a/kernel/Kconfig' "$file"
      ;;
    susfs_inline_hook_patches.sh)
      grep -q 'patch_files=' "$file"
      ;;
    *)
      echo "internal error: no validator for $name" >&2
      return 1
      ;;
  esac
}

# --- download + validate everything before touching any vendored file ---
printf 'Refreshing vendored patches in %s\n\n' "$TARGET"

for i in "${!names[@]}"; do
  name="${names[$i]}"
  url="${urls[$i]}"
  printf 'downloading %s ...\n' "$name"
  curl -fLSs --retry 3 --retry-delay 2 -o "$tmp/$name" "$url"
  if ! validate "$name" "$tmp/$name"; then
    echo "error: $url did not look like the expected $name; nothing was replaced" >&2
    exit 1
  fi
done

# --- replace only what actually changed ---
updated=0
for i in "${!names[@]}"; do
  name="${names[$i]}"
  dest="${dests[$i]}"
  mkdir -p -- "$(dirname -- "$dest")"

  if [ -f "$dest" ] && cmp -s "$tmp/$name" "$dest"; then
    printf 'OK      %s (unchanged)\n' "$dest"
    continue
  fi

  oldsha='(missing)'
  if [ -f "$dest" ]; then
    oldsha="$(sha256sum -- "$dest" | cut -d' ' -f1)"
    cp -p -- "$dest" "$tmp/old.$name"
  fi
  newsha="$(sha256sum -- "$tmp/$name" | cut -d' ' -f1)"

  mv -f -- "$tmp/$name" "$dest"
  updated=$((updated + 1))

  printf 'UPDATE  %s\n' "$dest"
  printf '  sha256: %s -> %s\n' "$oldsha" "$newsha"
  if [ -f "$tmp/old.$name" ]; then
    diff -u -- "$tmp/old.$name" "$dest" | head -n 60 || true
  fi
done

printf '\n%d file(s) updated in %s\n' "$updated" "$TARGET"
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo
  git -C "$TARGET" diff --stat -- . || true
fi
if [ "$updated" -gt 0 ]; then
  echo
  echo 'Review the diff above, re-run the canary, then push with ak-sync.sh.'
fi
