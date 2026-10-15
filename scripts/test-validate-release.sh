#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: "\([0-9.]*\)"/\1/p' project.yml)
export CI_TAG=

for tag in "v$version" "v$version-beta.1" "v$version-beta.12"; do
  scripts/validate-release.sh "$tag" >/dev/null
done
CI_TAG="v$version-beta.2" scripts/validate-release.sh >/dev/null

for tag in '' "$version" "v$version-beta.0" "v$version-beta.01" \
  "v$version-beta." "v$version-beta.1-extra" "v$version-rc.1" \
  "v999.999.999" "v999.999.999-beta.1"; do
  if scripts/validate-release.sh "$tag" >/dev/null 2>&1; then
    print -u2 "Unexpectedly accepted tag: $tag"
    exit 1
  fi
done
print 'Release tag validation passed.'
