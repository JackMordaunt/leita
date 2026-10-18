#!/usr/bin/env bash
# Fills packaging's channel templates from a release's sha256sums.txt.
# The manifests job runs this after assemble. A checkout can run it on a
# sums file from a dry run. It does not download anything.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: fill-manifests.sh SHA256SUMS OUT_DIR" >&2
  exit 2
fi

SUMS=$1
OUT=$2
here=$(cd "$(dirname "$0")" && pwd)

: "${VERSION:?VERSION must be set to the tag, like v1.2.0}"
case $VERSION in
  v[0-9A-Za-z]*) ;;
  *)
    echo "::error::VERSION must be a tag starting with v, not ${VERSION}" >&2
    exit 1
    ;;
esac
version=${VERSION#v}
case $version in
  *[!0-9A-Za-z._-]*)
    echo "::error::VERSION has a character a file name cannot carry" >&2
    exit 1
    ;;
esac

[ -f "$SUMS" ] || {
  echo "::error::no sha256sums file ${SUMS}" >&2
  exit 1
}

# sum_of prints the sha256 of an exact file name in sha256sums.txt.
# assemble writes that file with `sha256sum` in text mode (no -b):
# "<hash><two spaces><name>". read's IFS collapses the spaces, and none of
# these names contain one.
sum_of() {
  local name=$1 sum rest
  while read -r sum rest; do
    [ "$rest" = "$name" ] || continue
    printf '%s\n' "$sum"
    return 0
  done < "$SUMS"
  return 1
}

# sum_file hashes a file in this checkout. The desktop entry, the icon and
# the unit are not release assets, so they are not in sha256sums.txt; the
# tag's copies are hashed here.
sum_file() {
  local file=$1 sum
  [ -f "$file" ] || {
    echo "::error::no ${file} to sum" >&2
    exit 1
  }
  sum=$(sha256sum "$file")
  sum=${sum%% *}
  sum=${sum,,}
  [[ $sum =~ ^[0-9a-f]{64}$ ]] || {
    echo "::error::sha256 of ${file} is not 64 hex characters" >&2
    exit 1
  }
  printf '%s\n' "$sum"
}

require_sum() {
  local name=$1 sum
  sum=$(sum_of "$name") || {
    echo "::error::sha256sums.txt has no ${name}" >&2
    exit 1
  }
  sum=${sum,,}
  [[ $sum =~ ^[0-9a-f]{64}$ ]] || {
    echo "::error::sha256 of ${name} is not 64 hex characters" >&2
    exit 1
  }
  printf '%s\n' "$sum"
}

# The first name that sha256sums.txt actually lists. The signed asset is
# tried first; -unsigned is what a release is called before the certificate
# exists.
pick_one() {
  local name
  for name in "$@"; do
    if sum_of "$name" >/dev/null; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  echo "::error::sha256sums.txt has none of: $*" >&2
  exit 1
}

# subst copies a template, replacing each KEY VALUE pair. A token left
# behind means the job forgot a sum, so the file is not written.
subst() {
  local src=$1 dest=$2 tmp key value
  shift 2
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp)
  cp "$src" "$tmp"
  while [ "$#" -gt 0 ]; do
    key=$1
    value=$2
    shift 2
    case $value in
      *[\\/\&]*)
        echo "::error::${key} has a value sed cannot substitute safely" >&2
        exit 1
        ;;
    esac
    sed "s/${key}/${value}/g" "$tmp" > "$tmp.next"
    mv "$tmp.next" "$tmp"
  done
  if grep -n '__[A-Z][A-Z0-9_]*__' "$tmp"; then
    echo "::error::${dest} still holds an unfilled token" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

fill_winget() {
  local file_setup sum_setup
  file_setup=$(pick_one \
    "leita-v${version}-windows-amd64-setup.exe" \
    "leita-v${version}-windows-amd64-setup-unsigned.exe")
  sum_setup=$(require_sum "$file_setup")
  local src dest base
  for base in Librium.Leita.yaml Librium.Leita.installer.yaml Librium.Leita.locale.en-US.yaml; do
    src="${here}/winget/${base}"
    dest="${OUT}/winget/${base}"
    subst "$src" "$dest" \
      __FILE_SETUP__ "$file_setup" \
      __SUM_SETUP__ "$sum_setup" \
      __VERSION__ "$version"
  done
}

fill_homebrew() {
  local file_dmg sum_dmg sum_cli sum_amd64 sum_arm64
  file_dmg=$(pick_one \
    "leita-v${version}-darwin-universal.dmg" \
    "leita-v${version}-darwin-universal-unsigned.dmg")
  sum_dmg=$(require_sum "$file_dmg")
  sum_cli=$(require_sum "leita-v${version}-darwin-universal-cli.tar.zst")
  sum_amd64=$(require_sum "leita-v${version}-linux-amd64.tar.zst")
  sum_arm64=$(require_sum "leita-v${version}-linux-arm64.tar.zst")
  subst "${here}/homebrew/Casks/leita.rb" "${OUT}/homebrew/Casks/leita.rb" \
    __FILE_DMG__ "$file_dmg" \
    __SUM_DMG__ "$sum_dmg" \
    __VERSION__ "$version"
  subst "${here}/homebrew/Formula/leita.rb" "${OUT}/homebrew/Formula/leita.rb" \
    __SUM_DARWIN_CLI__ "$sum_cli" \
    __SUM_LINUX_AMD64__ "$sum_amd64" \
    __SUM_LINUX_ARM64__ "$sum_arm64" \
    __VERSION__ "$version"
}

fill_aur() {
  local root sum_desktop sum_metainfo sum_unit sum_icon sum_amd64 sum_arm64
  root=$(cd "$here/.." && pwd)
  sum_desktop=$(sum_file "$root/packaging/linux/dev.mordaunt.Leita.desktop")
  sum_metainfo=$(sum_file "$root/packaging/linux/dev.mordaunt.Leita.metainfo.xml")
  sum_unit=$(sum_file "$root/packaging/linux/leita-journal.service")
  sum_icon=$(sum_file "$root/branding/mark-light.svg")
  sum_amd64=$(require_sum "leita-v${version}-linux-amd64.tar.zst")
  sum_arm64=$(require_sum "leita-v${version}-linux-arm64.tar.zst")
  subst "${here}/aur/PKGBUILD" "${OUT}/aur/PKGBUILD" \
    __SUM_DESKTOP__ "$sum_desktop" \
    __SUM_METAINFO__ "$sum_metainfo" \
    __SUM_UNIT__ "$sum_unit" \
    __SUM_ICON__ "$sum_icon" \
    __SUM_LINUX_AMD64__ "$sum_amd64" \
    __SUM_LINUX_ARM64__ "$sum_arm64" \
    __VERSION__ "$version"
  subst "${here}/aur/.SRCINFO" "${OUT}/aur/.SRCINFO" \
    __SUM_DESKTOP__ "$sum_desktop" \
    __SUM_METAINFO__ "$sum_metainfo" \
    __SUM_UNIT__ "$sum_unit" \
    __SUM_ICON__ "$sum_icon" \
    __SUM_LINUX_AMD64__ "$sum_amd64" \
    __SUM_LINUX_ARM64__ "$sum_arm64" \
    __VERSION__ "$version"
}

fill_scoop() {
  local file_zip sum_zip suffix
  file_zip=$(pick_one \
    "leita-v${version}-windows-amd64.zip" \
    "leita-v${version}-windows-amd64-unsigned.zip")
  sum_zip=$(require_sum "$file_zip")
  # The zip's own name carries -unsigned before the certificate exists.
  # The directory inside it does not: release.yml packs leita-<version>-windows-amd64
  # and only the file name gains the suffix.
  suffix=
  case $file_zip in
    *-unsigned.zip) suffix=-unsigned ;;
  esac
  subst "${here}/scoop/leita.json" "${OUT}/scoop/leita.json" \
    __ZIP_SUFFIX__ "$suffix" \
    __SUM_ZIP__ "$sum_zip" \
    __VERSION__ "$version"
}

fill_winget
fill_homebrew
fill_aur
fill_scoop
