#!/bin/bash
# The jq programs in this file use $variables that are jq's, not the shell's.
# shellcheck disable=SC2016
#
# deploy-nocturne-azure.sh - deploy your own Nocturne to a cheap Azure Linux VM, from a Mac.
#
# The macOS version of Deploy-NocturneAzure.ps1 (Windows). Same steps, same Azure resources, same
# secrets file, so either script can manage a deployment made by the other.
#
#   1. Installs what it needs if missing: Homebrew (asks first), Azure CLI, jq and Bicep.
#   2. Signs you in to Azure (directories that require MFA: --tenant-id).
#   3. Lets you pick a region (sorted by price, cheapest recommended), finds the VM sizes YOUR
#      subscription can use there, offers the cheapest with 2/4/6/8 GB, shows the ESTIMATED
#      monthly cost from Azure's live price list, and asks before creating anything.
#   4. Creates the VM and its network with Bicep (infra/nocturne-vm.bicep).
#   5. The VM runs install-nocturne.sh on first boot (cloud-agnostic: any Ubuntu/Debian server).
#   6. Follows the install, then checks Nocturne answers over HTTPS.
#
# Usage (in Terminal, from this folder):
#   bash deploy-nocturne-azure.sh                          deploy (asks for region and size)
#   bash deploy-nocturne-azure.sh --tenant-id <tenant-id>  sign in to a specific directory (MFA)
#   bash deploy-nocturne-azure.sh --domain nocturne.example.com
#   bash deploy-nocturne-azure.sh --action info            address, IP, SSH
#   bash deploy-nocturne-azure.sh --action logs            container status and recent logs
#   bash deploy-nocturne-azure.sh --action reinstall       upload install-nocturne.sh and re-run it
#   bash deploy-nocturne-azure.sh --action ssh             shell on the VM
#   bash deploy-nocturne-azure.sh --action remove          delete everything in Azure (stops billing)
#
# Options:
#   --action NAME          deploy (default), info, logs, reinstall, ssh, remove
#   --location REGION      Azure region, e.g. westeurope (default: choose from a menu)
#   --vm-size SIZE         a specific VM size (default: choose from a menu with prices)
#   --domain NAME          your own domain (default: free <name>-<id>.<region>.cloudapp.azure.com)
#   --os-disk-gb N         32 (default), 64 or 128
#   --resource-group NAME  default rg-nocturne
#   --name NAME            resource name prefix, default nocturne
#   --ssh-key PATH         default ~/.ssh/nocturne_azure
#   --tenant-id ID         sign in to this Azure directory
#   --device-code          sign in with a code instead of a browser window
#   --yes                  skip the cost confirmation (the estimate is still shown)
#   --timeout MINUTES      how long to wait for setup, default 30
#   -h, --help             show this help
#
# Secrets are generated once and saved in ./secrets/<resource-group>.env. Back that file up.
# Works with the bash that ships with macOS (3.2); also runs on Linux.

set -uo pipefail

ACTION=deploy
RESOURCE_GROUP=rg-nocturne
LOCATION=''
NAME=nocturne
VM_SIZE=''
OS_DISK_GB=32
DOMAIN=''
SSH_KEY="$HOME/.ssh/nocturne_azure"
TENANT_ID=''
DEVICE_CODE=0
YES=0
TIMEOUT_MIN=30

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The commands this script prints for later (remove, logs, ...) are the one-line installer from
# GitHub with an action, so they work on any computer, from any folder. get-nocturne.sh passes
# its own address, so a fork or another branch prints its own.
GET_URL="${NOCTURNE_GET_URL:-https://raw.githubusercontent.com/bennettnicholas/nocturne/azure-cloud-deploymentscripts/deploy/azure-cloud/get-nocturne.sh}"
SELF="curl -fsSL $GET_URL | bash -s --"
TEMPLATE="$HERE/infra/nocturne-vm.bicep"
INSTALLER="$HERE/install-nocturne.sh"
SECRETS_DIR="$HERE/secrets"
DEPLOYMENT=nocturne
HOURS_PER_MONTH=730
MEMORY_TIERS='[2,4,6,8]'                      # GB; Nocturne needs 2 minimum, 4 recommended
REGION_REFERENCE_SIZES='Standard_B2als_v2 Standard_B2s'   # the cheapest 4 GB sizes in most regions
AZ=az
WORK=''

# ------------------------------------------------------------------ output
if [ -t 1 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_GRAY=$'\033[90m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_BOLD=''; C_OFF=''
fi
T0=$(date +%s)
stamp() { local e=$(( $(date +%s) - T0 )); printf '[%s +%02d:%02d]' "$(date +%H:%M:%S)" $((e / 60)) $((e % 60)); }
step()  { printf '\n%s%s ==> %s%s\n' "$C_CYAN" "$(stamp)" "$*" "$C_OFF"; }
ok()    { printf '%s%s   [ok] %s%s\n' "$C_GREEN" "$(stamp)" "$*" "$C_OFF"; }
warn()  { printf '%s%s   [!]  %s%s\n' "$C_YELLOW" "$(stamp)" "$*" "$C_OFF"; }
info()  { printf '%s%s        %s%s\n' "$C_GRAY" "$(stamp)" "$*" "$C_OFF"; }
say()   { printf '%s%s%s\n' "${2:-}" "$1" "$C_OFF"; }
# fail MESSAGE [HINT...]
fail() {
  printf '%s%s [FAILED] %s%s\n' "$C_RED" "$(stamp)" "$1" "$C_OFF"; shift
  local h; for h in "$@"; do printf '%s  - %s%s\n' "$C_YELLOW" "$h" "$C_OFF"; done
  exit 1
}
# ask PROMPT -> REPLY (reads the terminal even when stdin is a pipe)
ask() { REPLY=''; printf '%s' "$1" > /dev/tty; IFS= read -r REPLY < /dev/tty || REPLY=''; }
show_az() { printf '%s%s        > az %s%s\n' "$C_GRAY" "$(stamp)" "$*" "$C_OFF"; }

# Money and arithmetic in awk with a C locale: a comma decimal separator would break printf.
usd()  { LC_ALL=C awk -v v="${1:-}" 'BEGIN { if (v == "" || v == "null") print "n/a"; else printf "$%.2f", v }'; }
calc() { LC_ALL=C awk "BEGIN { printf \"%.6f\", $1 }"; }

# ------------------------------------------------------------------ pure helpers (unit-tested)

# Random secret from an alphabet without look-alike characters.
random_secret() {
  head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789' | cut -c "1-$1"
}

# Value of KEY in a KEY=value file (tolerates Windows line endings).
env_get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 | tr -d '\r'; }

# Lowest Linux pay-as-you-go hourly price per $k (armSkuName or armRegionName) from Retail API
# items: not Windows, not Spot / Low Priority, not the "Cloud Services" product.
PRICE_MIN_JQ='[ .[]
  | select((.productName // "") | startswith("Virtual Machines"))
  | select((.productName | test("Windows")) | not)
  | select((.skuName // "") | test("Spot|Low Priority") | not)
  | select(.retailPrice > 0) ]
| group_by(.[$k]) | map({ key: .[0][$k], value: (map(.retailPrice) | min) }) | from_entries'

# Sizes this subscription can deploy here. Input: [skus, usage] (usage may be null = quota unknown).
# Only whole-region restrictions matter (the VM is not pinned to a zone); restrictions may be null,
# [] or a list. Output: { candidates: [...], skipped: { reason: count } }.
CANDIDATES_JQ='
.[0] as $skus | .[1] as $usage
| (if $usage == null then null
   else ([ $usage[] | select(.name.value == "cores") | ((.limit | tonumber) - (.currentValue | tonumber)) ] | .[0]) end) as $regional
| (if $usage == null then {}
   else ([ $usage[] | select(.name.value != "cores")
           | { key: (.name.value | ascii_downcase), value: ((.limit | tonumber) - (.currentValue | tonumber)) } ] | from_entries) end) as $fam
| reduce ($skus[] | select(. != null and .name != null)) as $s ({ candidates: [], skipped: {} };
    ([ ($s.caps // [])[] | select(. != null and .name != null) | { key: .name, value: .value } ] | from_entries) as $c
    | (($c.vCPUs // "0") | tonumber) as $cpu
    | (if ([ ($s.restrictions // [])[] | select(. != null and .type == "Location") ] | length) > 0 then "not offered to your subscription here"
       elif $c.MemoryGB == null or $c.vCPUs == null then "no size information"
       elif (($c.HyperVGenerations // "") | test("V2") | not) then "no Gen2 support (Ubuntu 24.04 image)"
       elif (($c.GPUs // "0") | tonumber) > 0 then "GPU size"
       elif ($c.ConfidentialComputingType // "") != "" then "confidential computing size"
       elif $regional != null and $regional < $cpu then "not enough regional vCPU quota"
       elif $s.family != null and $fam[$s.family | ascii_downcase] != null and $fam[$s.family | ascii_downcase] < $cpu then "not enough vCPU quota for its family"
       else null end) as $why
    | if $why != null then .skipped[$why] += 1
      else .candidates += [{
        size: $s.name, family: $s.family, cpu: $cpu, mem: ($c.MemoryGB | tonumber),
        arch: (if $c.CpuArchitectureType == "Arm64" then "Arm64" else "x64" end),
        trustedLaunch: ($c.TrustedLaunchDisabled != "True"), hourly: null }]
      end)'

# For each memory tier, the cheapest priced candidate with at least that much RAM. A size that is
# cheapest for several tiers appears once. Input: candidates; $tiers: array of GB.
TIERS_JQ='
. as $c
| reduce $tiers[] as $t ([];
    ([ $c[] | select(.hourly != null and .mem >= $t) ] | sort_by(.hourly, .mem, .cpu) | .[0]) as $best
    | if $best == null then .
      elif any(.[]; .size == $best.size) then map(if .size == $best.size then .tiers += [$t] else . end)
      else . + [ $best + { tiers: [$t] } ] end)'

# Regions with prices, cheapest first, unpriced last. Input: [locations, { region: hourly }].
REGION_ROWS_JQ='
.[1] as $p
| [ .[0][] | select(. != null and .name != null and .geo != null)
    | { name, display, geo, hourly: $p[.name] } ]
| sort_by((.hourly == null), .hourly, .display)'

# Areas for the region menu: name, region count, cheapest region. Input: region rows.
AREAS_JQ='
group_by(.geo)
| map({ geo: .[0].geo, count: length, low: ([ .[] | select(.hourly != null) ] | sort_by(.hourly, .display) | .[0]) })'

# Text between [stdout] and [stderr] in a run-command message (the whole message if unmarked).
run_command_stdout() {
  if printf '%s\n' "$1" | grep -q '^\[stdout\]'; then
    printf '%s\n' "$1" | awk '/^\[stdout\]/ { f = 1; next } /^\[stderr\]/ { f = 0 } f'
  else
    printf '%s\n' "$1"
  fi
}

# ------------------------------------------------------------------ Azure price list (public)
# https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
# retail_items FILTER -> JSON array of price items on stdout (follows NextPageLink, max 20 pages).
retail_items() {
  local enc uri n=0 dir
  enc=$(jq -rn --arg f "$1" '$f | @uri')
  uri="https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&\$filter=$enc"
  dir=$(mktemp -d "$WORK/retail.XXXXXX")
  while [ -n "$uri" ] && [ "$n" -lt 20 ]; do
    if ! curl -fsS --max-time 30 -o "$dir/$n.json" "$uri" 2>/dev/null; then rm -f "$dir/$n.json"; break; fi
    uri=$(jq -r '.NextPageLink // empty' "$dir/$n.json")
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then echo '[]'; else jq -s '[ .[].Items[]? ]' "$dir"/*.json; fi
  rm -rf "$dir"
}

# vm_prices SIZE... -> { size: hourly } for $LOCATION, in batches of 8 sizes per query.
vm_prices() {
  local out="$WORK/vmprices.parts" names='' count=0 s
  : > "$out"
  flush() {
    [ -n "$names" ] || return 0
    retail_items "serviceName eq 'Virtual Machines' and armRegionName eq '$LOCATION' and priceType eq 'Consumption' and ($names)" \
      | jq --arg k armSkuName "$PRICE_MIN_JQ" >> "$out"
    names=''; count=0
  }
  for s in "$@"; do
    if [ -n "$names" ]; then names="$names or "; fi
    names="${names}armSkuName eq '$s'"
    count=$((count + 1))
    if [ "$count" -eq 8 ]; then flush; fi
  done
  flush
  jq -s 'add // {}' "$out"
}

# region_prices -> { region: hourly } for the reference sizes (one query per size covers all regions).
region_prices() {
  local s out="$WORK/rprices.parts"
  : > "$out"
  for s in $REGION_REFERENCE_SIZES; do
    retail_items "serviceName eq 'Virtual Machines' and armSkuName eq '$s' and priceType eq 'Consumption'" \
      | jq --arg k armRegionName "$PRICE_MIN_JQ" >> "$out"
  done
  # Cheapest of the reference sizes per region.
  jq -s 'reduce (.[] | to_entries[]) as $e ({}; if .[$e.key] == null or $e.value < .[$e.key] then .[$e.key] = $e.value else . end)' "$out"
}

disk_tier() { case "$1" in 32) echo E4 ;; 64) echo E6 ;; *) echo E10 ;; esac; }
disk_monthly() {
  retail_items "serviceName eq 'Storage' and armRegionName eq '$LOCATION' and productName eq 'Standard SSD Managed Disks' and meterName eq '$(disk_tier "$1") LRS Disk' and priceType eq 'Consumption'" \
    | jq -r '.[0].retailPrice // empty'
}
ip_hourly() {
  retail_items "serviceName eq 'Virtual Network' and armRegionName eq '$LOCATION' and meterName eq 'Standard IPv4 Static Public IP' and priceType eq 'Consumption'" \
    | jq -r '.[0].retailPrice // empty'
}

# ------------------------------------------------------------------ 1. tools on this Mac
find_brew() {
  if command -v brew > /dev/null 2>&1; then return 0; fi
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
  done
  return 1
}

setup_tools() {
  step 'Tools on this computer'
  local missing=''
  command -v az > /dev/null 2>&1 || missing="$missing azure-cli"
  command -v jq > /dev/null 2>&1 || missing="$missing jq"
  if [ -n "$missing" ]; then
    if ! find_brew; then
      [ "$(uname -s)" = Darwin ] || fail "Missing:$missing." 'Install the Azure CLI (https://aka.ms/installazurecli) and jq, then re-run.'
      warn "Homebrew (the standard macOS package manager, https://brew.sh) is needed to install:$missing"
      ask 'Install Homebrew now? It asks for your Mac password. (Y/N) '
      case "$REPLY" in [Yy]*) ;; *) fail 'Homebrew is required.' 'Install it from https://brew.sh, then re-run.' ;; esac
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty \
        || fail 'Homebrew install failed (see the output above).' 'Install it from https://brew.sh, then re-run.'
      find_brew || fail 'Homebrew was installed but cannot be found.' 'Open a new Terminal window and re-run.'
    fi
    info "Installing with Homebrew:$missing (a few minutes)..."
    # shellcheck disable=SC2086
    brew install $missing || fail "brew install$missing failed (see the output above)."
  fi
  AZ=$(command -v az) || fail 'Azure CLI is still not found.' 'Open a new Terminal window and re-run.'
  ok "Azure CLI $("$AZ" version --query '"azure-cli"' -o tsv 2>/dev/null)"
  ok "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"

  if ! "$AZ" bicep version > /dev/null 2>&1; then
    info 'Installing the Bicep compiler (az bicep install)...'
    "$AZ" bicep install || true
    "$AZ" bicep version > /dev/null 2>&1 || fail 'Could not install the Bicep compiler.' 'Run: az bicep install   and check the error.'
  fi
  ok "Bicep $("$AZ" bicep version 2>/dev/null | sed 's/^Bicep CLI version *//')"

  command -v ssh-keygen > /dev/null 2>&1 || fail 'The OpenSSH client (ssh, ssh-keygen) is missing.'
  command -v curl > /dev/null 2>&1 || fail 'curl is missing.'
  ok 'OpenSSH client and curl found'
}

# ------------------------------------------------------------------ Azure helpers
az_read() { show_az "$*"; "$AZ" "$@" || fail "az $1 $2 failed (see the Azure output above)."; }

# Runs a shell script on the VM through the Azure agent; prints its stdout. Returns 1 if unreachable.
vm_shell() {
  local f="$WORK/vmshell.sh" json msg
  printf '%s\n' "$1" > "$f"
  json=$("$AZ" vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript --scripts "@$f" -o json 2>/dev/null) || return 1
  msg=$(printf '%s' "$json" | jq -r '.value[0].message // empty')
  run_command_stdout "$msg"
}

# Reads the deployment outputs into O_* variables. Returns 1 if there is no deployment.
load_outputs() {
  local json
  json=$("$AZ" deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT" --query properties.outputs -o json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  O_BASE=$(printf '%s' "$json" | jq -r '.baseDomain.value // empty')
  O_FQDN=$(printf '%s' "$json" | jq -r '.azureFqdn.value // empty')
  O_IP=$(printf '%s' "$json" | jq -r '.publicIpAddress.value // empty')
  O_USER=$(printf '%s' "$json" | jq -r '.adminUsername.value // empty')
  O_CUSTOM=$(printf '%s' "$json" | jq -r '.usesCustomDomain.value // false')
  [ -n "$O_BASE" ]
}

show_info() {
  echo
  say "  Nocturne:  https://$O_BASE" "$C_GREEN"
  echo "  Public IP: $O_IP"
  echo "  SSH:       $SELF --action ssh      (ssh -i \"$SSH_KEY\" $O_USER@$O_FQDN)"
  echo "  Logs:      $SELF --action logs"
  echo "  Remove:    $SELF --action remove   (deletes everything in Azure, stops billing)"
  echo "  Secrets:   $SECRETS_FILE   (back this up)"
}

# ------------------------------------------------------------------ 2. sign in
sign_in() {
  step 'Checking Azure sign-in'
  local signed_in=0 current
  if "$AZ" account show --output table; then signed_in=1; fi
  if [ "$signed_in" = 1 ] && [ -n "$TENANT_ID" ]; then
    current=$("$AZ" account show --query tenantId -o tsv 2>/dev/null)
    if [ "$current" != "$TENANT_ID" ]; then info "Switching directory to $TENANT_ID."; signed_in=0; fi
  fi
  if [ "$signed_in" = 0 ]; then
    step 'Signing in to Azure (complete MFA and pick your subscription if asked)'
    set -- login
    if [ -n "$TENANT_ID" ]; then set -- "$@" --tenant "$TENANT_ID"; fi
    if [ "$DEVICE_CODE" = 1 ]; then set -- "$@" --use-device-code; fi
    show_az "$*"
    "$AZ" "$@" || fail 'az login failed (see the Azure output above).'
  fi
  "$AZ" account show --output none 2>/dev/null || fail 'Signed in, but no Azure subscription is available.' \
    'If Azure said you must use multi-factor authentication (AADSTS50076), re-run with --tenant-id <tenant-id>.' \
    'Add --device-code if the MFA prompt does not appear.'
  ok "Subscription: $("$AZ" account show --query name -o tsv 2>/dev/null)"
}

# ------------------------------------------------------------------ actions other than deploy
other_action() {
  if ! load_outputs && [ "$ACTION" != remove ]; then
    fail "No Nocturne deployment found in '$RESOURCE_GROUP'. Deploy first:  curl -fsSL $GET_URL | bash"
  fi
  case "$ACTION" in
    info) show_info ;;
    ssh)  rm -rf "$WORK"; exec ssh -i "$SSH_KEY" "$O_USER@$O_FQDN" ;;
    logs)
      step 'Container status and recent logs (through the Azure agent)'
      vm_shell "cd /opt/nocturne && docker compose ps && echo && echo '--- install log ---' && tail -n 15 /var/log/nocturne-install.log && echo && echo '--- last 40 log lines ---' && docker compose logs --tail 40 --no-color" \
        || fail 'Could not reach the VM through the Azure agent. Is it running?'
      ;;
    reinstall)
      step 'Uploading install-nocturne.sh to the VM and re-running it (keeps .env and data)'
      local b64 out
      b64=$(tr -d '\r' < "$INSTALLER" | base64 | tr -d '\n')
      out=$(vm_shell "echo '$b64' | base64 -d > /opt/nocturne/install-nocturne.sh && chmod 700 /opt/nocturne/install-nocturne.sh && /opt/nocturne/install-nocturne.sh > /tmp/nocturne-reinstall.out 2>&1; code=\$?; tail -n 25 /tmp/nocturne-reinstall.out; exit \$code") \
        || fail 'The installer failed or the VM could not be reached.' "Details:  $SELF --action logs"
      printf '%s\n' "$out"
      case "$out" in *NOCTURNE_INSTALL_DONE*) ok 'Reinstall finished' ;; *) fail 'Reinstall did not finish (output above).' ;; esac
      ;;
    remove)
      say "This permanently deletes resource group '$RESOURCE_GROUP': the VM, its disk with all Nocturne data, the IP and the network. Billing for them stops." "$C_YELLOW"
      ask 'Type the resource group name to confirm: '
      if [ "$REPLY" != "$RESOURCE_GROUP" ]; then echo 'Cancelled.'; exit 0; fi
      show_az "group delete -n $RESOURCE_GROUP --yes --no-wait"
      "$AZ" group delete -n "$RESOURCE_GROUP" --yes --no-wait || fail 'az group delete failed (see the Azure output above).'
      ok "Deletion of '$RESOURCE_GROUP' started (takes a few minutes)."
      info "The secrets file is kept: $SECRETS_FILE. Delete it yourself if you won't redeploy."
      ;;
  esac
  exit 0
}

# ------------------------------------------------------------------ region and size
# Interactive region choice: area first, then a region in it, cheapest recommended. Sets LOCATION.
select_region() {
  info 'Loading Azure regions and comparing prices...'
  "$AZ" account list-locations \
    --query "[?metadata.regionType=='Physical'].{name:name, display:displayName, geo:metadata.geographyGroup}" \
    -o json > "$WORK/locations.json" 2>/dev/null || fail 'Could not list Azure regions.' 'Pass a region with --location (e.g. westeurope).'
  region_prices > "$WORK/region-prices.json"
  jq -s "$REGION_ROWS_JQ" "$WORK/locations.json" "$WORK/region-prices.json" > "$WORK/regions.json"
  jq "$AREAS_JQ" "$WORK/regions.json" > "$WORK/areas.json"
  local areas n i pick geo
  areas=$(jq 'length' "$WORK/areas.json")
  [ "$areas" -gt 0 ] || fail 'No Azure regions found.' 'Pass a region with --location (e.g. westeurope).'

  echo
  say '  Where should Nocturne run? Your health data is stored in this region, so choose one' "$C_BOLD"
  say '  that suits where you live (privacy rules such as the GDPR may apply). A nearer region' "$C_BOLD"
  say '  also feels faster. Prices: a 4 GB VM per month, list price (estimate).' "$C_BOLD"
  local cheap
  cheap=$(jq -r --argjson h "$HOURS_PER_MONTH" '[ .[] | select(.hourly != null) ] | .[0] | if . then "\(.display) (\(.name))\t\(.hourly * $h)" else empty end' "$WORK/regions.json")
  if [ -n "$cheap" ]; then say "  Cheapest region overall: ${cheap%%	*} at about $(usd "${cheap#*	}")/month." "$C_GREEN"; fi
  echo
  i=0
  while IFS=$'\t' read -r geo n low_name low_h; do
    i=$((i + 1))
    if [ -n "$low_h" ]; then low="from $(usd "$low_h")/month ($low_name)"; else low='prices n/a'; fi
    printf '  %-3s %-16s %2s regions   %s\n' "$i" "$geo" "$n" "$low"
  done < <(jq -r --argjson h "$HOURS_PER_MONTH" '.[] | [ .geo, .count, (.low.display // ""), (if .low then .low.hourly * $h else "" end) ] | @tsv' "$WORK/areas.json")
  echo
  ask "Choose an area [1-$areas]: "; pick=$REPLY
  case "$pick" in ''|*[!0-9]*) fail "Invalid choice '$pick'." ;; esac
  { [ "$pick" -ge 1 ] && [ "$pick" -le "$areas" ]; } || fail "Invalid choice '$pick'."
  geo=$(jq -r --argjson i "$((pick - 1))" '.[$i].geo' "$WORK/areas.json")
  jq --arg g "$geo" '[ .[] | select(.geo == $g) ]' "$WORK/regions.json" > "$WORK/in-area.json"

  echo
  printf '  %-3s %-26s %-22s %14s\n' '#' 'Region' 'Name (for --location)' '4 GB VM/month'
  local count name display hourly price note
  count=$(jq 'length' "$WORK/in-area.json")
  i=0
  while IFS=$'\t' read -r name display hourly; do
    i=$((i + 1))
    note=''; price='n/a'
    if [ -n "$hourly" ]; then price=$(usd "$(calc "$hourly * $HOURS_PER_MONTH")"); [ "$i" = 1 ] && note='recommended: cheapest here'; fi
    printf '  %-3s %-26s %-22s %14s   %s\n' "$i" "$display" "$name" "$price" "$note"
  done < <(jq -r '.[] | [ .name, .display, (.hourly // "") ] | @tsv' "$WORK/in-area.json")
  say '  Some regions need special access; if one has no usable sizes, the script lets you pick again.' "$C_GRAY"
  echo
  ask "Choose a region [1-$count, Enter = 1]: "; pick=${REPLY:-1}
  case "$pick" in *[!0-9]*) fail "Invalid choice '$pick'." ;; esac
  { [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ]; } || fail "Invalid choice '$pick'."
  LOCATION=$(jq -r --argjson i "$((pick - 1))" '.[$i].name' "$WORK/in-area.json")
}

# Writes $WORK/candidates.json: the sizes this subscription can use in $LOCATION.
# Uses the Compute SKUs REST API with a server-side region filter and only the needed fields (fast).
available_sizes() {
  info "Asking Azure which VM sizes your subscription can use in $LOCATION (about 10-20 seconds)..."
  local sub url query
  sub=$("$AZ" account show --query id -o tsv 2>/dev/null)
  url="https://management.azure.com/subscriptions/$sub/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq '$LOCATION'"
  query="value[?resourceType=='virtualMachines'].{name:name, family:family, restrictions:restrictions, caps:capabilities[?name=='MemoryGB' || name=='vCPUs' || name=='HyperVGenerations' || name=='CpuArchitectureType' || name=='GPUs' || name=='ConfidentialComputingType' || name=='TrustedLaunchDisabled']}"
  "$AZ" rest --method get --url "$url" --query "$query" -o json > "$WORK/skus.json" 2>/dev/null \
    || fail "Could not list VM sizes for $LOCATION." 'Check the region name (e.g. eastus2, westeurope), then re-run.'
  [ "$(jq 'length' "$WORK/skus.json")" -gt 0 ] \
    || fail "Azure returned no VM sizes for '$LOCATION'." 'Check the region name (e.g. eastus2, westeurope), or run without --location to pick one.'
  if ! "$AZ" vm list-usage -l "$LOCATION" -o json > "$WORK/usage.json" 2>/dev/null; then
    warn 'Could not read your vCPU quota; quota is not checked.'
    echo null > "$WORK/usage.json"
  fi
  jq -s "$CANDIDATES_JQ" "$WORK/skus.json" "$WORK/usage.json" > "$WORK/candidates.json"
}

# ------------------------------------------------------------------ deploy
deploy() {
  [ -f "$TEMPLATE" ] || fail "Missing file: $TEMPLATE"
  [ -f "$INSTALLER" ] || fail "Missing file: $INSTALLER"
  # The installer runs on Linux: make sure it has Unix line endings.
  if grep -q $'\r' "$INSTALLER"; then
    tr -d '\r' < "$INSTALLER" > "$WORK/installer.lf" && cat "$WORK/installer.lf" > "$INSTALLER"
    info 'Converted install-nocturne.sh to Unix line endings'
  fi

  step 'Your public IP (SSH is only allowed from here)'
  local my_ip
  my_ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  if ! printf '%s' "$my_ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    ask 'Could not detect it. Enter your public IPv4 address: '; my_ip=$REPLY
  fi
  ok "$my_ip"

  step 'SSH key'
  if [ ! -f "$SSH_KEY.pub" ]; then
    mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
    info "Creating a key at $SSH_KEY (press Enter twice for no passphrase, or type one)."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C nocturne-azure < /dev/tty
    [ -f "$SSH_KEY.pub" ] || fail 'SSH key was not created.'
  fi
  ok "Using $SSH_KEY.pub"

  step 'Region'
  local existing chose_here=0
  existing=$("$AZ" group show -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
  if [ -n "$existing" ]; then
    # A resource group (and the VM in it) can't move regions: re-runs stay where they are.
    if [ -n "$LOCATION" ] && [ "$LOCATION" != "$existing" ]; then
      warn "Resource group '$RESOURCE_GROUP' already exists in $existing, so that region is used."
      warn 'For a new deployment somewhere else, pass a different --resource-group.'
    fi
    LOCATION=$existing
    ok "Using $LOCATION (where '$RESOURCE_GROUP' already is)"
  elif [ -n "$LOCATION" ]; then
    ok "Using $LOCATION (from --location)"
  else
    select_region; chose_here=1
    ok "Region: $LOCATION"
  fi

  step "VM sizes your subscription can use in $LOCATION"
  local count
  while :; do
    available_sizes
    count=$(jq '.candidates | length' "$WORK/candidates.json")
    ok "$count sizes are available to your subscription in $LOCATION"
    jq -r '.skipped | to_entries | sort_by(.key) | .[] | "skipped \(.value): \(.key)"' "$WORK/candidates.json" | while IFS= read -r l; do info "$l"; done
    [ "$count" -gt 0 ] && break
    [ "$chose_here" = 1 ] || fail "No usable VM sizes for your subscription in $LOCATION." \
      'Run without --location to choose another region (sorted by price).' 'Or request more vCPU quota: Azure portal > Quotas > Compute.'
    warn "No usable VM sizes for your subscription in $LOCATION (it may need special access, or your quota there is 0). Please pick another region."
    select_region
    ok "Region: $LOCATION"
  done

  step "VM size and estimated cost ($LOCATION, live list prices)"
  info 'Looking up prices for the small sizes...'
  local ip_h disk_m fixed
  ip_h=$(ip_hourly); disk_m=$(disk_monthly "$OS_DISK_GB")
  fixed=''
  if [ -n "$ip_h" ] && [ -n "$disk_m" ]; then fixed=$(calc "$disk_m + $ip_h * $HOURS_PER_MONTH"); fi
  # Price only what the menu can show (up to 16 GB, 4 vCPUs), plus a size named with --vm-size.
  # shellcheck disable=SC2046
  vm_prices $( { jq -r '.candidates[] | select(.mem <= 16 and .cpu <= 4) | .size' "$WORK/candidates.json"; [ -n "$VM_SIZE" ] && echo "$VM_SIZE"; } | sort -u) > "$WORK/prices.json"
  jq --slurpfile p "$WORK/prices.json" '.candidates | map(.hourly = $p[0][.size])' "$WORK/candidates.json" > "$WORK/priced.json"

  if [ -n "$VM_SIZE" ]; then
    jq --arg s "$VM_SIZE" '[ .[] | select(.size == $s) ] | .[0] // empty' "$WORK/priced.json" > "$WORK/chosen.json"
    [ -s "$WORK/chosen.json" ] || fail "$VM_SIZE is not available to your subscription in $LOCATION (restricted, out of quota, or not offered)." \
      'Run without --vm-size to choose from the sizes you can use.'
  else
    jq --argjson tiers "$MEMORY_TIERS" "$TIERS_JQ" "$WORK/priced.json" > "$WORK/tiers.json"
    local rows i=0 def=1 tiers size cpu arch mem hourly vm_m tot note pick
    rows=$(jq 'length' "$WORK/tiers.json")
    [ "$rows" -gt 0 ] || fail "Could not get prices for any usable size in $LOCATION." 'Try again later, or pass --vm-size.'
    echo
    say '  Cheapest sizes available to YOUR subscription, by memory (estimates, per month):' "$C_BOLD"
    printf '  %-3s %-9s %-20s %-12s %6s %10s %11s\n' '#' 'Tier' 'Size' 'CPU' 'RAM' 'VM' 'Total*'
    while IFS=$'\t' read -r tiers size cpu arch mem hourly; do
      i=$((i + 1))
      vm_m=$(calc "$hourly * $HOURS_PER_MONTH")
      tot=''; [ -n "$fixed" ] && tot=$(calc "$vm_m + $fixed")
      case ",$tiers," in
        *,4,*) note=recommended; def=$i ;;
        *) if [ "${tiers%%,*}" = 2 ] && [ "$(calc "$mem < 4")" = '1.000000' ]; then note='minimum spec: can feel slow'; else note='more headroom'; fi ;;
      esac
      printf '  %-3s %-9s %-20s %-12s %6s %10s %11s   %s\n' "$i" "$(echo "$tiers" | tr ',' '/') GB" "$size" "$cpu vCPU $arch" "$mem GB" "$(usd "$vm_m")" "$(usd "$tot")" "$note"
    done < <(jq -r '.[] | [ (.tiers | map(tostring) | join(",")), .size, .cpu, .arch, .mem, .hourly ] | @tsv' "$WORK/tiers.json")
    say '  * Total = VM + disk + static IP. List prices; your bill can differ.' "$C_GRAY"
    echo
    ask "Choose a size [1-$rows, Enter = $def]: "; pick=${REPLY:-$def}
    case "$pick" in *[!0-9]*) fail "Invalid choice '$pick'." ;; esac
    { [ "$pick" -ge 1 ] && [ "$pick" -le "$rows" ]; } || fail "Invalid choice '$pick'."
    jq --argjson i "$((pick - 1))" '.[$i]' "$WORK/tiers.json" > "$WORK/chosen.json"
    VM_SIZE=$(jq -r '.size' "$WORK/chosen.json")
  fi
  local c_cpu c_arch c_mem c_hourly c_tl
  c_cpu=$(jq -r '.cpu' "$WORK/chosen.json"); c_arch=$(jq -r '.arch' "$WORK/chosen.json")
  c_mem=$(jq -r '.mem' "$WORK/chosen.json"); c_hourly=$(jq -r '.hourly // empty' "$WORK/chosen.json")
  c_tl=$(jq -r '.trustedLaunch' "$WORK/chosen.json")
  ok "$VM_SIZE ($c_cpu vCPU $c_arch, $c_mem GB) is available to your subscription"
  if [ "$(calc "$c_mem < 2")" = '1.000000' ]; then warn "Less than 2 GB RAM: below Nocturne's minimum."; fi

  local vm_month='' ip_month='' total=''
  [ -n "$c_hourly" ] && vm_month=$(calc "$c_hourly * $HOURS_PER_MONTH")
  [ -n "$ip_h" ] && ip_month=$(calc "$ip_h * $HOURS_PER_MONTH")
  if [ -n "$vm_month" ] && [ -n "$disk_m" ] && [ -n "$ip_month" ]; then total=$(calc "$vm_month + $disk_m + $ip_month"); fi

  echo
  say '  ESTIMATED cost of running Nocturne 24/7 (USD, pay-as-you-go list prices)' "$C_YELLOW"
  printf '    VM %-32s %10s /month\n' "$VM_SIZE (Linux)" "$(usd "$vm_month")"
  printf '    OS disk %-27s %10s /month\n' "$OS_DISK_GB GB Standard SSD ($(disk_tier "$OS_DISK_GB"))" "$(usd "$disk_m")"
  printf '    %-35s %10s /month\n' 'Static public IP' "$(usd "$ip_month")"
  echo   '    ----------------------------------------------------'
  if [ -n "$total" ]; then
    printf '%s    %-35s %10s /month  (about %s per day)%s\n' "$C_YELLOW" 'Total (estimate)' "$(usd "$total")" "$(usd "$(calc "$total / 30.4")")" "$C_OFF"
  else
    say '    Total: could not get every price from Azure. See https://azure.microsoft.com/pricing/calculator/' "$C_YELLOW"
  fi
  echo
  say '  This is ONLY AN ESTIMATE. Your actual bill can differ: it uses list prices for' "$C_YELLOW"
  say "  $LOCATION at $HOURS_PER_MONTH hours a month, and does not include data transfer beyond the free" "$C_YELLOW"
  say '  allowance, disk transactions, backups or taxes, or any discounts, credits or currency' "$C_YELLOW"
  say '  conversion on your account. Check your costs in the Azure portal (Cost Management).' "$C_YELLOW"
  say "  The VM bills until you remove it:  $SELF --action remove" "$C_YELLOW"
  echo
  if [ "$YES" = 1 ]; then
    info '--yes given: continuing without asking.'
  else
    ask 'Create the VM and start billing? (Y/N) '
    case "$REPLY" in [Yy]*) ;; *) echo 'Cancelled. Nothing was created.'; exit 0 ;; esac
  fi

  step 'Secrets'
  if [ -f "$SECRETS_FILE" ]; then
    ok "Reusing secrets from $SECRETS_FILE (the database was created with these)"
    local first_domain
    first_domain=$(env_get CUSTOM_DOMAIN "$SECRETS_FILE")
    if grep -q '^CUSTOM_DOMAIN=' "$SECRETS_FILE" && [ "$first_domain" != "$DOMAIN" ]; then
      warn "The first deployment used domain '$first_domain' but this run uses '$DOMAIN'."
      warn 'The VM keeps its first .env. To change the domain, edit BASE_DOMAIN in /opt/nocturne/.env over SSH and run: docker compose up -d'
    fi
  else
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    ( umask 077
      { echo "# Nocturne on Azure: secrets for resource group $RESOURCE_GROUP"
        echo '# Keep a copy somewhere safe. Losing INSTANCE_KEY makes stored connector secrets unreadable.'
        echo "INSTANCE_KEY=$(random_secret 64)"
        echo "POSTGRES_PASSWORD=$(random_secret 40)"
        echo "POSTGRES_APP_PASSWORD=$(random_secret 40)"
        echo "POSTGRES_MIGRATOR_PASSWORD=$(random_secret 40)"
        echo "POSTGRES_WEB_PASSWORD=$(random_secret 40)"
        echo "CUSTOM_DOMAIN=$DOMAIN"
      } > "$SECRETS_FILE" )
    ok "Generated new secrets and saved them to $SECRETS_FILE (not shown)"
    warn 'Back that file up somewhere other than this computer.'
  fi

  step "Resource group $RESOURCE_GROUP in $LOCATION"
  az_read group create -n "$RESOURCE_GROUP" -l "$LOCATION" --output table

  step "Creating the VM and network with Bicep ($VM_SIZE, Ubuntu 24.04) - about 3-5 minutes"
  local image_sku=server
  [ "$c_arch" = Arm64 ] && image_sku=server-arm64
  # Secure values go in a temporary parameters file (read from the secrets file), never on a command line.
  local params="$WORK/params.json"
  ( umask 077
    jq -Rn --arg name "$NAME" --arg size "$VM_SIZE" --arg image "$image_sku" --argjson tl "$c_tl" \
      --argjson disk "$OS_DISK_GB" --arg key "$(tr -d '\r\n' < "$SSH_KEY.pub")" --arg cidr "$my_ip/32" --arg domain "$DOMAIN" '
      ([ inputs | sub("\r$"; "") | capture("^(?<k>[A-Z_]+)=(?<v>.*)$")? ] | map({ (.k): .v }) | add) as $s
      | { "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
          contentVersion: "1.0.0.0",
          parameters: {
            name: { value: $name }, vmSize: { value: $size }, imageSku: { value: $image },
            trustedLaunch: { value: $tl }, osDiskSizeGb: { value: $disk },
            sshPublicKey: { value: $key }, sshAllowedCidr: { value: $cidr }, customDomain: { value: $domain },
            instanceKey: { value: $s.INSTANCE_KEY }, postgresPassword: { value: $s.POSTGRES_PASSWORD },
            postgresAppPassword: { value: $s.POSTGRES_APP_PASSWORD },
            postgresMigratorPassword: { value: $s.POSTGRES_MIGRATOR_PASSWORD },
            postgresWebPassword: { value: $s.POSTGRES_WEB_PASSWORD } } }' < "$SECRETS_FILE" > "$params" )
  [ "$(jq -r '[ .parameters[] | .value | select(. == null) ] | length' "$params")" = 0 ] \
    || fail "$SECRETS_FILE is missing a value." 'Restore it from your backup (the database was created with those passwords).'
  az_read deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT" --template-file "$TEMPLATE" \
    --parameters "@$params" --query properties.provisioningState --output tsv
  rm -f "$params"
  load_outputs || fail 'Deployment finished but its outputs could not be read.'
  ok "VM is up at $O_IP ($O_FQDN)"

  if [ "$O_CUSTOM" = true ]; then
    step "DNS for $O_BASE"
    say '  Create these two records at your DNS provider:' "$C_YELLOW"
    echo "    A   $O_BASE      ->  $O_IP"
    echo "    A   *.$O_BASE    ->  $O_IP      (tenant subdomains and share links)"
    info 'Waiting until the domain resolves to the VM (checks every 20s; create the records now)...'
    local until=$(( $(date +%s) + TIMEOUT_MIN * 60 )) resolved
    while :; do
      resolved=$(resolve_a "$O_BASE")
      if printf '%s\n' "$resolved" | grep -qx "$O_IP"; then ok "$O_BASE resolves to $O_IP"; break; fi
      [ "$(date +%s)" -gt "$until" ] && fail "DNS for $O_BASE still doesn't point to $O_IP." 'Create the records above, then re-run (re-runs are safe).'
      info "...not yet (currently: $(if [ -n "$resolved" ]; then echo "$resolved" | tr '\n' ' '; else echo 'no record'; fi))"
      sleep 20
    done
  fi

  step 'install-nocturne.sh is running on the VM (Docker, then the release bundle) - about 5-10 minutes'
  local until=$(( $(date +%s) + TIMEOUT_MIN * 60 )) out newest last=''
  while :; do
    if out=$(vm_shell 'tail -n 3 /var/log/nocturne-install.log 2>/dev/null || echo "(waiting for first-boot setup to start)"; cloud-init status 2>/dev/null | tail -n 1'); then
      newest=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | grep -v '^status:' | tail -n 1)
      if [ -n "$newest" ] && [ "$newest" != "$last" ]; then info "VM: $newest"; last=$newest; else info '...still working'; fi
      case "$out" in *NOCTURNE_INSTALL_DONE*) ok 'install-nocturne.sh finished: containers are running'; break ;; esac
      case "$out" in *ERROR:*|*'status: error'*)
        fail 'install-nocturne.sh failed on the VM.' "Details:  $SELF --action logs" "After fixing:  $SELF --action reinstall" ;;
      esac
    else
      info '...VM agent not answering yet'
    fi
    [ "$(date +%s)" -gt "$until" ] && fail "Setup did not finish in $TIMEOUT_MIN minutes." "Check:  $SELF --action logs"
    sleep 15
  done

  step "Waiting for https://$O_BASE (Caddy gets the Let's Encrypt certificate on first start)"
  local code
  until=$(( $(date +%s) + 600 ))
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-redirs 5 --max-time 15 "https://$O_BASE/" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" -lt 500 ]; then ok "Nocturne answered with HTTP $code"; break; fi
    if [ -n "$code" ] && [ "$code" != 000 ]; then info "...HTTP $code, services still starting"; else info '...not ready yet (no HTTPS answer)'; fi
    if [ "$(date +%s)" -gt "$until" ]; then
      warn 'Nocturne did not answer over HTTPS within 10 minutes. It may still be starting.'
      info "Check:  $SELF --action logs"
      break
    fi
    sleep 15
  done

  step 'Nocturne is deployed'
  show_info
  echo
  local setup_url="https://$O_BASE/setup"
  say "  Next: finish the first-run setup (create the owner account) at  $setup_url" "$C_CYAN"
  [ -n "$total" ] && say "  Estimated running cost: about $(usd "$total") a month (estimate only)." "$C_CYAN"
  say "  Remove everything (stops billing):  $SELF --action remove" "$C_CYAN"
  ask 'Open the setup page in your browser now? (Y/N) '
  case "$REPLY" in [Yy]*) if command -v open > /dev/null 2>&1; then open "$setup_url"; else xdg-open "$setup_url" 2>/dev/null || true; fi ;; esac
}

# IPv4 addresses DOMAIN resolves to, one per line.
resolve_a() {
  if command -v dig > /dev/null 2>&1; then dig +short A "$1" 2>/dev/null | grep -E '^[0-9.]+$'
  elif command -v host > /dev/null 2>&1; then host -t A "$1" 2>/dev/null | awk '/has address/ { print $NF }'
  else getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u; fi
}

# ------------------------------------------------------------------ main
usage() { sed -n '/^# deploy-nocturne-azure.sh - /,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --action)         ACTION=$(printf '%s' "${2:?--action needs a value}" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      --resource-group) RESOURCE_GROUP=${2:?}; shift 2 ;;
      --location)       LOCATION=$(printf '%s' "${2:?}" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      --name)           NAME=${2:?}; shift 2 ;;
      --vm-size)        VM_SIZE=${2:?}; shift 2 ;;
      --os-disk-gb)     OS_DISK_GB=${2:?}; shift 2 ;;
      --domain)         DOMAIN=$(printf '%s' "${2:?}" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      --ssh-key)        SSH_KEY=${2:?}; shift 2 ;;
      --tenant-id)      TENANT_ID=${2:?}; shift 2 ;;
      --device-code)    DEVICE_CODE=1; shift ;;
      --yes|-y)         YES=1; shift ;;
      --timeout)        TIMEOUT_MIN=${2:?}; shift 2 ;;
      -h|--help)        usage; exit 0 ;;
      *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
  done
  case "$ACTION" in deploy|info|logs|reinstall|ssh|remove) ;; *) fail "Unknown --action '$ACTION'." 'Use deploy, info, logs, reinstall, ssh or remove.' ;; esac
  case "$OS_DISK_GB" in 32|64|128) ;; *) fail '--os-disk-gb must be 32, 64 or 128.' ;; esac
  case "$TIMEOUT_MIN" in ''|*[!0-9]*) fail '--timeout must be a number of minutes.' ;; esac
  # Empty means "pick from the menu". (Not `printf | grep`: grep given no input at all never matches.)
  case "$LOCATION" in *[!a-z0-9]*) fail "Invalid --location '$LOCATION' (e.g. westeurope)." ;; esac
  case "$NAME" in
    [a-z]*[!a-z0-9-]*|[!a-z]*|?|?????????????????????*) fail "Invalid --name '$NAME' (2-20 lowercase letters, digits, hyphens)." ;;
  esac
  SECRETS_FILE="$SECRETS_DIR/$RESOURCE_GROUP.env"
  VM_NAME="$NAME-vm"
}

main() {
  parse_args "$@"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/nocturne-deploy.XXXXXX") || fail 'Could not create a temporary folder.'
  chmod 700 "$WORK"
  trap 'rm -rf "$WORK"' EXIT
  setup_tools
  sign_in
  if [ "$ACTION" != deploy ]; then other_action; fi
  deploy
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
