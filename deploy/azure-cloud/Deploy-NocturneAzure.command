#!/bin/bash
# Double-click in Finder to deploy Nocturne to Azure (macOS). Runs deploy-nocturne-azure.sh.
# If macOS blocks it: right-click > Open, or in Terminal run:  bash deploy-nocturne-azure.sh
cd "$(dirname "$0")" || exit 1
/bin/bash ./deploy-nocturne-azure.sh "$@"
echo
read -r -p 'Press Enter to close this window...' _
