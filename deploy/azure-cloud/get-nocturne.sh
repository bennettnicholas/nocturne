#!/bin/bash
# get-nocturne.sh - one-line installer for macOS (and Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/nightscout/nocturne/main/deploy/azure-cloud/get-nocturne.sh | bash
#
# With options (passed to deploy-nocturne-azure.sh):
#   curl -fsSL https://raw.githubusercontent.com/nightscout/nocturne/main/deploy/azure-cloud/get-nocturne.sh | bash -s -- --tenant-id <tenant-id>
#
# Downloads the toolkit files from GitHub into ~/nocturne-azure (an update keeps your secrets/
# folder), then runs deploy-nocturne-azure.sh. Re-run it any time to update and deploy again.
set -euo pipefail

# Everything is inside main(), called on the last line: bash reads the whole script before running
# any of it, so a download cut off halfway through `curl | bash` does nothing instead of half a job.
main() {

  # Where the toolkit is published (override with environment variables for testing):
  REPO="${NOCTURNE_TOOLS_REPO:-nightscout/nocturne}"
  BRANCH="${NOCTURNE_TOOLS_BRANCH:-main}"   # or a release tag for a fixed version
  BASE_URL="${NOCTURNE_TOOLS_BASE_URL:-https://raw.githubusercontent.com/$REPO/$BRANCH/deploy/azure-cloud}"
  DEST="${NOCTURNE_TOOLS_DIR:-$HOME/nocturne-azure}"

  # The toolkit: only these files are downloaded, not the whole repository.
  files="Deploy-NocturneAzure.ps1 deploy-nocturne-azure.sh infra/nocturne-vm.bicep"

  printf '\033[36m==> Downloading the Nocturne deploy toolkit (%s, %s)\033[0m\n' "$REPO" "$BRANCH"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/nocturne-get.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  # Everything is downloaded before anything is copied, so a failed download leaves the old
  # toolkit as it was.
  for file in $files; do
    mkdir -p "$tmp/$(dirname "$file")"
    curl -fsSL --retry 3 -o "$tmp/$file" "$BASE_URL/$file" || { echo "Could not download $BASE_URL/$file" >&2; exit 1; }
  done
  mkdir -p "$DEST"
  # Copy over the old version; secrets/ and logs/ are not in the download, so they are kept.
  cp -R "$tmp/." "$DEST/"
  chmod +x "$DEST"/*.sh 2>/dev/null || true
  printf '\033[32m    Toolkit is in %s\033[0m\n' "$DEST"

  printf '\033[36m==> Starting deploy-nocturne-azure.sh\033[0m\n'
  cd "$DEST"
  status=0
  # The deploy script prints this command (with an action) for later, so it shows this address.
  export NOCTURNE_GET_URL="$BASE_URL/get-nocturne.sh"
  # With `curl | bash`, stdin is the pipe, so give the deploy script the terminal instead.
  if [ -r /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    bash ./deploy-nocturne-azure.sh "$@" < /dev/tty || status=$?
  else
    bash ./deploy-nocturne-azure.sh "$@" < /dev/null || status=$?
  fi
  echo
  echo "Run it again later:  curl -fsSL $NOCTURNE_GET_URL | bash"
  return "$status"
}

main "$@"
