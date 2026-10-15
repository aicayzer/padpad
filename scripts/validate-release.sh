#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."
tag="${1:-${CI_TAG:-}}"
[[ "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$' ]] || {
  print -u2 'Distribution requires vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N (N > 0).'
  exit 1
}
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: "\([0-9.]*\)"/\1/p' project.yml)
tag_version="${tag#v}"
tag_version="${tag_version%%-beta.*}"
[[ "$tag_version" == "$version" ]] || {
  print -u2 "Tag $tag does not match project version $version."
  exit 1
}
print "Validated release $tag."
