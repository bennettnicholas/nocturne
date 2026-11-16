<#
.SYNOPSIS
    One script, run on your PC, that deploys a real Nocturne instance to a cheap Azure Linux VM.

.DESCRIPTION
    What it does, in order:
      1. Installs what it needs on this PC if missing: Azure CLI (winget) and the Bicep compiler.
      2. Signs you in to Azure (handles directories that require MFA: -TenantId).
      3. Lets you pick a region (sorted by price, cheapest recommended), then finds the VM sizes
         YOUR subscription can use there (restrictions and vCPU quota checked), offers the
         cheapest for 2/4/6/8 GB, shows the ESTIMATED monthly cost from Azure's live price list,
         and asks before creating anything.
      4. Creates the VM and its network with Bicep (infra\nocturne-vm.bicep).
      5. The VM runs Nocturne's install script (the released install.sh) on first boot.
      6. Sets or shows the DNS records, follows the install, then checks Nocturne answers over HTTPS.

    Nocturne runs from its official Docker Compose release bundle: PostgreSQL, API, web app,
    gateway, Caddy (automatic HTTPS) and Watchtower (automatic updates).

    Domain: Nocturne needs a domain whose name and wildcard (*.domain) point at the VM. Without
    -Domain the script asks for one. A free name from duckdns.org works: give the script your
    DuckDNS token and it sets the record for you. Otherwise it lists the two records to create.

    Secrets are generated once and saved in .\secrets\<resource-group>.env. Back that file up.

.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -TenantId <tenant-id>      # deploy (asks for size, shows cost)
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Location westeurope -Domain nocturne.example.com -VmSize Standard_B2als_v2
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Action Info        # address, IP, SSH
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Action Logs        # container status and recent logs
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Action Reinstall   # run the install script on the VM again
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Action Ssh         # shell on the VM
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -Action Remove      # delete everything in Azure (stops billing)
#>
[CmdletBinding()]
param(
    [ValidateSet('Deploy', 'Info', 'Logs', 'Reinstall', 'Ssh', 'Remove')]
    [string]$Action = 'Deploy',
    [string]$ResourceGroup = 'rg-nocturne',
    [ValidatePattern('^[a-z0-9]*$')]
    [string]$Location = '',               # empty = choose from a menu (sorted by price)
    [ValidatePattern('^[a-z][a-z0-9-]{1,19}$')]
    [string]$Name = 'nocturne',
    [string]$VmSize = '',                 # empty = choose from a menu with prices
    [ValidateSet(32, 64, 128)]
    [int]$OsDiskGb = 32,
    [string]$Domain = '',
    [string]$SshKeyPath = (Join-Path $HOME '.ssh\nocturne_azure'),
    [string]$TenantId = '',
    [switch]$DeviceCode,
    [switch]$Yes,                         # skip the cost confirmation (the estimate is still shown)
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:T0 = Get-Date
function Stamp { '[{0:HH:mm:ss} +{1:mm\:ss}]' -f (Get-Date), ((Get-Date) - $script:T0) }
function Step([string]$m) { Write-Host ''; Write-Host "$(Stamp) ==> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "$(Stamp)   [ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "$(Stamp)   [!]  $m" -ForegroundColor Yellow }
function Info([string]$m) { Write-Host "$(Stamp)        $m" -ForegroundColor Gray }
function Fail([string]$m, [string[]]$hints = @()) {
    Write-Host "$(Stamp) [FAILED] $m" -ForegroundColor Red
    foreach ($h in $hints) { Write-Host "  - $h" -ForegroundColor Yellow }
    exit 1
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

$Template    = Join-Path $PSScriptRoot 'infra\nocturne-vm.bicep'
$InstallScriptUrl = 'https://github.com/nightscout/nocturne/releases/latest/download/install.sh'
$SecretsDir  = Join-Path $PSScriptRoot 'secrets'
$SecretsFile = Join-Path $SecretsDir "$ResourceGroup.env"
# The commands this script prints for later (remove, logs, ...) are the one-line installer from
# GitHub with an action, so they work on any computer, from any folder. get-nocturne.ps1 passes
# its own address, so a fork or another branch prints its own.
$GetUrl      = 'https://raw.githubusercontent.com/nightscout/nocturne/main/deploy/azure-cloud/get-nocturne.ps1'
if ($env:NOCTURNE_GET_URL) { $GetUrl = $env:NOCTURNE_GET_URL }
$GetCommand  = "irm $GetUrl | iex"
$Self        = "& ([scriptblock]::Create((irm $GetUrl)))"
$Deployment  = 'nocturne'
$VmName      = "$Name-vm"

# Memory tiers offered in the size menu: the cheapest size YOUR subscription can use with at least
# this much RAM. Nocturne needs 2 GB minimum, 4 GB recommended.
$MemoryTiers = @(2, 4, 6, 8)

# ================================================================ 1. tools on this PC
Step 'Tools on this PC'
Refresh-Path
function Find-Az {
    $c = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $c) {
        $default = Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        if (Test-Path $default) { $c = $default }
    }
    return $c
}
# Always call Azure CLI by its full path: a bare `az` could resolve to a PowerShell function.
$script:AzExe = Find-Az
if (-not $script:AzExe) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'Azure CLI is not installed, and winget is not available to install it.' @('Install Azure CLI from https://aka.ms/installazurecliwindows, then re-run.')
    }
    Info 'Installing Azure CLI with winget (a few minutes; Windows may ask for permission)...'
    & winget install --id Microsoft.AzureCLI -e --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
    Refresh-Path
    $script:AzExe = Find-Az
    if (-not $script:AzExe) { Fail 'Azure CLI install failed.' @('Install it from https://aka.ms/installazurecliwindows, then re-run.') }
}
$azVersion = (& $script:AzExe version -o json 2>$null | Out-String | ConvertFrom-Json).'azure-cli'
Ok "Azure CLI $azVersion"

$null = & $script:AzExe bicep version 2>$null
if ($LASTEXITCODE -ne 0) {
    Info 'Installing the Bicep compiler (az bicep install)...'
    & $script:AzExe bicep install 2>&1 | Out-Host
    $null = & $script:AzExe bicep version 2>$null
    if ($LASTEXITCODE -ne 0) { Fail 'Could not install the Bicep compiler.' @('Run: az bicep install   and check the error.') }
}
Ok "Bicep $((& $script:AzExe bicep version 2>$null | Out-String).Trim() -replace '^Bicep CLI version\s*', '')"

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Fail 'The OpenSSH client (ssh, ssh-keygen) is missing.' @('Settings > System > Optional features > View features > add "OpenSSH Client", then re-run.')
}
Ok 'OpenSSH client found'

# ================================================================ Azure CLI helpers
function Show-AzCommand([object[]]$azArgs) {
    Write-Host "$(Stamp)        > az $($azArgs -join ' ')" -ForegroundColor DarkGray
}
function Assert-Az([object[]]$azArgs) {
    if ($LASTEXITCODE -ne 0) { Fail "az $(($azArgs | Select-Object -First 2) -join ' ') failed (see the Azure output above)." }
}
function Invoke-AzRead { Show-AzCommand $args; $out = & $script:AzExe @args; Assert-Az $args; return $out }
function Invoke-AzShow { Show-AzCommand $args; & $script:AzExe @args | Out-Host; Assert-Az $args }

# Runs a shell script on the VM through the Azure agent and returns its stdout. The script goes in
# a temp file (@file): az is a .cmd, and cmd.exe would mangle quotes, && and pipes.
function Invoke-VmShell([string]$script) {
    $tmp = Join-Path $env:TEMP "nocturne-vmshell-$PID.sh"
    [IO.File]::WriteAllText($tmp, ($script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    $json = & $script:AzExe vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunShellScript --scripts "@$tmp" -o json 2>$null
    $code = $LASTEXITCODE
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($code -ne 0) { return $null }
    $msg = (($json | Out-String) | ConvertFrom-Json).value[0].message
    if ($msg -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\]') { return $Matches[1] }
    return $msg
}

function Get-DeploymentOutputs {
    $json = & $script:AzExe deployment group show -g $ResourceGroup -n $Deployment --query properties.outputs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $o = ($json | Out-String) | ConvertFrom-Json
    return [pscustomobject]@{
        BaseDomain = $o.baseDomain.value; AzureFqdn = $o.azureFqdn.value; Ip = $o.publicIpAddress.value
        User = $o.adminUsername.value
    }
}

function New-Secret([int]$length) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ================================================================ cost estimate (Azure Retail Prices API)
# Public, no sign-in needed: https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
function Get-RetailItems([string]$filter) {
    $uri = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&$filter=' + [uri]::EscapeDataString($filter)
    $all = @(); $pages = 0
    while ($uri -and $pages -lt 20) {
        try { $r = Invoke-RestMethod -Uri $uri -TimeoutSec 30 } catch { break }
        $all += @($r.Items); $uri = $r.NextPageLink; $pages++
    }
    return $all
}

# Linux pay-as-you-go hourly prices for many sizes at once: @{ size = price }.
function Get-VmPrices([string[]]$sizes) {
    $map = @{}
    for ($i = 0; $i -lt $sizes.Count; $i += 8) {
        $batch = $sizes[$i..([Math]::Min($i + 7, $sizes.Count - 1))]
        $names = ($batch | ForEach-Object { "armSkuName eq '$_'" }) -join ' or '
        $items = Get-RetailItems "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and priceType eq 'Consumption' and ($names)"
        # Not Windows, not Spot / Low Priority, not the "Cloud Services" product.
        foreach ($p in ($items | Where-Object { $_.productName -like 'Virtual Machines*' -and $_.productName -notmatch 'Windows' -and $_.skuName -notmatch 'Spot|Low Priority' })) {
            $price = [double]$p.retailPrice
            if ($price -gt 0 -and (-not $map.ContainsKey($p.armSkuName) -or $price -lt $map[$p.armSkuName])) { $map[$p.armSkuName] = $price }
        }
    }
    return $map
}

# Turns `az vm list-skus` + `az vm list-usage` output into the sizes this subscription can actually
# deploy here. Pure (no Azure calls) so it can be tested against recorded output.
#   $skus:         objects with name, family, restrictions, caps (capabilities: name/value pairs)
#   $familyFree:   @{ lowercase family = vCPUs left in quota }   (empty = quota unknown, not checked)
#   $regionalFree: total regional vCPUs left, or $null if unknown
# Returns candidates with Size, Family, Cpu, MemGB, Arch, TrustedLaunch; plus counts of why others were skipped.
function ConvertTo-SizeCandidates($skus, $familyFree, $regionalFree) {
    $out = @(); $skipped = @{}
    function Skip($why) { if ($skipped.ContainsKey($why)) { $skipped[$why]++ } else { $skipped[$why] = 1 } }
    foreach ($s in @($skus)) {
        if (-not $s -or -not $s.name) { continue }
        # Only whole-region restrictions matter: the VM is not pinned to an availability zone.
        # (Azure may send restrictions as null, [] or a list: count real entries only.)
        if (@(@($s.restrictions) | Where-Object { $_ -and $_.type -eq 'Location' }).Count -gt 0) { Skip 'not offered to your subscription here'; continue }
        $c = @{}; foreach ($x in @($s.caps)) { if ($x -and $x.name) { $c[$x.name] = $x.value } }
        if (-not $c['MemoryGB'] -or -not $c['vCPUs']) { Skip 'no size information'; continue }
        $mem = [double]$c['MemoryGB']; $cpu = [int]$c['vCPUs']
        if ($c['HyperVGenerations'] -notmatch 'V2') { Skip 'no Gen2 support (Ubuntu 24.04 image)'; continue }
        if ($c['GPUs'] -and [int]$c['GPUs'] -gt 0) { Skip 'GPU size'; continue }
        if ($c['ConfidentialComputingType']) { Skip 'confidential computing size'; continue }
        if ($null -ne $regionalFree -and $regionalFree -lt $cpu) { Skip 'not enough regional vCPU quota'; continue }
        if ($familyFree.Count -gt 0 -and $s.family) {
            $f = $familyFree[$s.family.ToLower()]
            if ($null -ne $f -and $f -lt $cpu) { Skip 'not enough vCPU quota for its family'; continue }
        }
        $arch = 'x64'; if ($c['CpuArchitectureType'] -eq 'Arm64') { $arch = 'Arm64' }
        $out += [pscustomobject]@{
            Size = $s.name; Family = $s.family; Cpu = $cpu; MemGB = $mem; Arch = $arch
            TrustedLaunch = ($c['TrustedLaunchDisabled'] -ne 'True'); Hourly = $null
        }
    }
    return [pscustomobject]@{ Candidates = $out; Skipped = $skipped }
}

# For each memory tier, the cheapest priced candidate with at least that much RAM. A size that is
# cheapest for several tiers appears once. Pure, so it can be tested.
function Select-CheapestTiers($candidates, [int[]]$tiers) {
    $rows = @()
    foreach ($t in $tiers) {
        $best = $candidates | Where-Object { $null -ne $_.Hourly -and $_.MemGB -ge $t } |
            Sort-Object Hourly, MemGB, Cpu | Select-Object -First 1
        if (-not $best) { continue }
        $existing = $rows | Where-Object { $_.Size -eq $best.Size } | Select-Object -First 1
        if ($existing) { $existing.Tiers = @($existing.Tiers) + $t; continue }
        $rows += [pscustomobject]@{
            Tiers = @($t); Size = $best.Size; Cpu = $best.Cpu; MemGB = $best.MemGB
            Arch = $best.Arch; TrustedLaunch = $best.TrustedLaunch; Hourly = $best.Hourly
        }
    }
    return $rows
}

# Reference size for comparing regions: the cheapest 4 GB size in most regions.
$RegionReferenceSizes = @('Standard_B2als_v2', 'Standard_B2s')

# Linux pay-as-you-go hourly price of the reference sizes in every region: @{ region = cheapest }.
# One query per size covers all regions.
function Get-RegionPrices {
    $map = @{}
    foreach ($s in $RegionReferenceSizes) {
        $items = Get-RetailItems "serviceName eq 'Virtual Machines' and armSkuName eq '$s' and priceType eq 'Consumption'"
        foreach ($p in ($items | Where-Object { $_.productName -like 'Virtual Machines*' -and $_.productName -notmatch 'Windows' -and $_.skuName -notmatch 'Spot|Low Priority' })) {
            $price = [double]$p.retailPrice
            if ($price -gt 0 -and (-not $map.ContainsKey($p.armRegionName) -or $price -lt $map[$p.armRegionName])) { $map[$p.armRegionName] = $price }
        }
    }
    return $map
}

# Builds the region list with prices, sorted cheapest first (unpriced last). Pure, so it can be tested.
#   $locations: objects with name, display, geo     $prices: @{ region = hourly }
function Get-RegionRows($locations, $prices) {
    $rows = foreach ($l in @($locations)) {
        if (-not $l -or -not $l.name -or -not $l.geo) { continue }
        $h = $null; if ($prices.ContainsKey($l.name)) { $h = $prices[$l.name] }
        [pscustomobject]@{ Name = $l.name; Display = $l.display; Geo = $l.geo; Hourly = $h }
    }
    return @($rows | Sort-Object @{ Expression = { $null -eq $_.Hourly } }, Hourly, Display)
}

# Interactive region choice: area first, then a region in it, cheapest recommended.
function Select-Region {
    Info 'Loading Azure regions and comparing prices...'
    $json = & $script:AzExe account list-locations --query "[?metadata.regionType=='Physical'].{name:name, display:displayName, geo:metadata.geographyGroup}" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { Fail 'Could not list Azure regions.' @('Pass a region with -Location (e.g. westeurope).') }
    $rows = Get-RegionRows (($json | Out-String) | ConvertFrom-Json) (Get-RegionPrices)
    if ($rows.Count -eq 0) { Fail 'No Azure regions found.' @('Pass a region with -Location (e.g. westeurope).') }

    $cheapest = $rows | Where-Object { $null -ne $_.Hourly } | Select-Object -First 1
    Write-Host ''
    Write-Host '  Where should Nocturne run? Your health data is stored in this region, so choose one' -ForegroundColor White
    Write-Host '  that suits where you live (privacy rules such as the GDPR may apply). A nearer region' -ForegroundColor White
    Write-Host '  also feels faster. Prices: a 4 GB VM per month, list price (estimate).' -ForegroundColor White
    if ($cheapest) { Write-Host ("  Cheapest region overall: {0} ({1}) at about {2}/month." -f $cheapest.Display, $cheapest.Name, (Format-Usd ($cheapest.Hourly * $HoursPerMonth))) -ForegroundColor Green }
    Write-Host ''
    $geos = @($rows | Group-Object Geo | Sort-Object Name)
    $i = 0
    foreach ($g in $geos) {
        $i++
        $low = $g.Group | Where-Object { $null -ne $_.Hourly } | Select-Object -First 1
        $lowText = if ($low) { "from $(Format-Usd ($low.Hourly * $HoursPerMonth))/month ($($low.Display))" } else { 'prices n/a' }
        Write-Host ('  {0,-3} {1,-16} {2,2} regions   {3}' -f $i, $g.Name, $g.Count, $lowText)
    }
    Write-Host ''
    $pick = Read-Host "Choose an area [1-$($geos.Count)]"
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $geos.Count) { Fail "Invalid choice '$pick'." }
    $inGeo = @($geos[[int]$pick - 1].Group)

    Write-Host ''
    Write-Host ('  {0,-3} {1,-26} {2,-22} {3,14}   {4}' -f '#', 'Region', 'Name (for -Location)', '4 GB VM/month', '')
    $i = 0
    foreach ($r in $inGeo) {
        $i++
        $note = ''; if ($i -eq 1 -and $null -ne $r.Hourly) { $note = 'recommended: cheapest here' }
        $priceText = if ($null -ne $r.Hourly) { Format-Usd ($r.Hourly * $HoursPerMonth) } else { 'n/a' }
        Write-Host ('  {0,-3} {1,-26} {2,-22} {3,14}   {4}' -f $i, $r.Display, $r.Name, $priceText, $note)
    }
    Write-Host '  Some regions need special access; if one has no usable sizes, the script lets you pick again.' -ForegroundColor DarkGray
    Write-Host ''
    $pick = Read-Host "Choose a region [1-$($inGeo.Count), Enter = 1]"
    if (-not $pick) { $pick = '1' }
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $inGeo.Count) { Fail "Invalid choice '$pick'." }
    return $inGeo[[int]$pick - 1].Name
}

# Asks Azure which sizes this subscription can use in $Location.
# Uses the Compute SKUs REST API with a server-side region filter and keeps only the fields the
# script needs: ~10 seconds, versus several minutes for `az vm list-skus`, which downloads every
# size in full and is slow to parse in Windows PowerShell.
# Note: ConvertFrom-Json output is assigned to a variable before use. In Windows PowerShell,
# @(... | ConvertFrom-Json) wraps a JSON array as ONE item, which silently breaks the filtering.
function Get-AvailableSizes {
    Info "Asking Azure which VM sizes your subscription can use in $Location (about 10-20 seconds)..."
    $subId = (& $script:AzExe account show --query id -o tsv 2>$null | Out-String).Trim()
    $url = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$Location'"
    $query = "value[?resourceType=='virtualMachines'].{name:name, family:family, restrictions:restrictions, caps:capabilities[?name=='MemoryGB' || name=='vCPUs' || name=='HyperVGenerations' || name=='CpuArchitectureType' || name=='GPUs' || name=='ConfidentialComputingType' || name=='TrustedLaunchDisabled']}"
    $json = & $script:AzExe rest --method get --url $url --query $query -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { Fail "Could not list VM sizes for $Location." @('Check the region name (e.g. eastus2, westeurope), then re-run.') }
    $skus = ($json | Out-String) | ConvertFrom-Json
    if (@($skus).Count -eq 0) { Fail "Azure returned no VM sizes for '$Location'." @('Check the region name (e.g. eastus2, westeurope), or run without -Location to pick one.') }
    $familyFree = @{}; $regionalFree = $null
    $usage = & $script:AzExe vm list-usage -l $Location -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $usage) {
        $usageList = ($usage | Out-String) | ConvertFrom-Json
        foreach ($u in $usageList) {
            $left = [int]$u.limit - [int]$u.currentValue
            if ($u.name.value -eq 'cores') { $regionalFree = $left } else { $familyFree[$u.name.value.ToLower()] = $left }
        }
    } else {
        Warn 'Could not read your vCPU quota; quota is not checked.'
    }
    return ConvertTo-SizeCandidates $skus $familyFree $regionalFree
}
function Get-DiskMonthly([int]$gb) {
    $tier = switch ($gb) { 32 { 'E4' } 64 { 'E6' } default { 'E10' } }
    $p = Get-RetailItems "serviceName eq 'Storage' and armRegionName eq '$Location' and productName eq 'Standard SSD Managed Disks' and meterName eq '$tier LRS Disk' and priceType eq 'Consumption'" | Select-Object -First 1
    if ($p) { return [pscustomobject]@{ Tier = $tier; Price = [double]$p.retailPrice } } else { return [pscustomobject]@{ Tier = $tier; Price = $null } }
}
function Get-IpHourly {
    $p = Get-RetailItems "serviceName eq 'Virtual Network' and armRegionName eq '$Location' and meterName eq 'Standard IPv4 Static Public IP' and priceType eq 'Consumption'" | Select-Object -First 1
    if ($p) { return [double]$p.retailPrice } else { return $null }
}
function Format-Usd($v) { if ($null -eq $v) { return 'n/a' } return ('${0:N2}' -f $v) }
$HoursPerMonth = 730

# ================================================================ 2. sign in
# az login, into $TenantId when set. Without one, --allow-no-subscriptions lets the sign-in succeed
# even when the default directory has no subscription (or wants MFA), so the directory picker can
# run afterwards instead of the sign-in failing. Returns whether az login succeeded.
function Invoke-AzLogin {
    $loginArgs = @('login')
    if ($script:TenantId) { $loginArgs += @('--tenant', $script:TenantId) } else { $loginArgs += '--allow-no-subscriptions' }
    if ($DeviceCode)      { $loginArgs += '--use-device-code' }
    Show-AzCommand $loginArgs
    & $script:AzExe @loginArgs | Out-Host
    return ($LASTEXITCODE -eq 0)
}
# The enabled subscriptions of this sign-in. A tenant-level account (from --allow-no-subscriptions)
# has the tenant's id as its id, so it is not one. (Filtered here, not with --query: az is a .cmd,
# and cmd.exe would mangle the && and ! of a JMESPath filter.)
function Get-Subscriptions {
    $json = & $script:AzExe account list --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
    return @(($json | Out-String | ConvertFrom-Json) | Where-Object { $_.state -eq 'Enabled' -and $_.id -ne $_.tenantId })
}
# Asks which directory (tenant) to use, from the ones this account belongs to. Sets $TenantId.
function Select-Tenant {
    # The Azure tenants API, through az rest: `az account tenant list` is an extension, not core.
    $json = & $script:AzExe rest --method get --url 'https://management.azure.com/tenants?api-version=2022-12-01' --output json 2>$null
    $tenants = @()
    # The ( ) and ForEach-Object unroll the list: PowerShell 5.1's ConvertFrom-Json returns a JSON
    # array as one object.
    if ($LASTEXITCODE -eq 0 -and $json) {
        $parsed = $json | Out-String | ConvertFrom-Json
        if ($parsed.value) { $tenants = @(($parsed.value) | ForEach-Object { $_ }) }
    }
    if ($tenants.Count -eq 1) {
        $script:TenantId = $tenants[0].tenantId
        Info "Using your only directory: $(if ($tenants[0].displayName) { $tenants[0].displayName } else { $tenants[0].tenantId })"
        return
    }
    if ($tenants.Count -gt 1) {
        Write-Host ''
        Write-Host '  Your account belongs to these directories (tenants):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $tenants.Count; $i++) {
            $t = $tenants[$i]
            $label = if ($t.displayName) { $t.displayName } else { '(no name)' }
            Write-Host ("  {0}) {1}  {2}  {3}" -f ($i + 1), $label, $t.defaultDomain, $t.tenantId)
        }
        Write-Host ''
        $pick = Read-Host "Which directory has your Azure subscription? (1-$($tenants.Count))"
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $tenants.Count) { Fail "Invalid choice '$pick'." }
        $script:TenantId = $tenants[$n - 1].tenantId
        return
    }
    # The list is not available (for example, the sign-in itself was refused): ask for the ID.
    Write-Host '  Azure could not list your directories. Find your tenant ID in the Azure portal:' -ForegroundColor Yellow
    Write-Host '  Microsoft Entra ID > Overview > Tenant ID (or your domain, e.g. contoso.onmicrosoft.com).' -ForegroundColor Yellow
    $entry = ((Read-Host 'Tenant ID or domain') -replace '\s', '')
    if ($entry -notmatch '^[A-Za-z0-9.-]+$') { Fail "Invalid tenant '$entry'." }
    $script:TenantId = $entry
}

Step 'Checking Azure sign-in'
& $script:AzExe account show --output none 2>$null
$signedIn = ($LASTEXITCODE -eq 0)
if ($signedIn -and $TenantId) {
    $current = & $script:AzExe account show --query tenantId -o tsv 2>$null
    if ($current -ne $TenantId) { Info "Switching directory to $TenantId."; $signedIn = $false }
}
if (-not $signedIn) {
    Step 'Signing in to Azure (complete MFA in the browser)'
    if (-not (Invoke-AzLogin) -and $TenantId) {
        Fail 'az login failed (see the Azure output above).' @(
            'Check the tenant ID, or run without -TenantId to pick a directory from a list.',
            'Add -DeviceCode if the browser sign-in does not appear.')
    }
}
# No subscription here (wrong directory, or one that needs MFA): ask which directory to use and
# sign in to it. A directory without a subscription asks again.
$tries = 0
while ((Get-Subscriptions).Count -eq 0) {
    $tries++
    if ($tries -gt 3) {
        Fail 'No Azure subscription found in the directories tried.' @(
            'Create one at https://portal.azure.com (Subscriptions > Add), then run this again.')
    }
    if ($tries -eq 1) { Info 'This sign-in has no Azure subscription yet. Pick the directory that has one.' }
    else { Warn 'There is no enabled Azure subscription in that directory.' }
    $TenantId = ''
    Select-Tenant
    Step "Signing in to directory $TenantId (complete MFA in the browser)"
    if (-not (Invoke-AzLogin)) { Fail 'az login failed (see the Azure output above).' @('Add -DeviceCode if the browser sign-in does not appear.') }
}
# A tenant-level account can still be the default after --allow-no-subscriptions: switch to a
# real subscription.
$sub = Invoke-AzRead account show --query '{id:id, name:name, tenant:tenantId}' --output json | ConvertFrom-Json
if ($sub.id -eq $sub.tenant) {
    $first = (Get-Subscriptions)[0]
    & $script:AzExe account set --subscription $first.id
    $sub = [pscustomobject]@{ id = $first.id; name = $first.name; tenant = $first.tenantId }
}
Ok "Subscription: $($sub.name)  (directory $($sub.tenant))"

# ================================================================ actions other than Deploy
function Show-Info($o) {
    Write-Host ''
    Write-Host "  Nocturne:  https://$($o.BaseDomain)" -ForegroundColor Green
    Write-Host "  Public IP: $($o.Ip)"
    Write-Host "  SSH:       $Self -Action Ssh      (ssh -i `"$SshKeyPath`" $($o.User)@$($o.AzureFqdn))"
    Write-Host "  Logs:      $Self -Action Logs"
    Write-Host "  Remove:    $Self -Action Remove   (deletes everything in Azure, stops billing)"
    Write-Host "  Secrets:   $SecretsFile   (back this up)"
}

if ($Action -ne 'Deploy') {
    $o = Get-DeploymentOutputs
    if (-not $o -and $Action -ne 'Remove') { Fail "No Nocturne deployment found in '$ResourceGroup'. Deploy first:  $GetCommand" }
    switch ($Action) {
        'Info' { Show-Info $o; exit 0 }
        'Ssh'  { & ssh -i $SshKeyPath "$($o.User)@$($o.AzureFqdn)"; exit $LASTEXITCODE }
        'Logs' {
            Step 'Container status and recent logs (through the Azure agent)'
            $out = Invoke-VmShell "cd /opt/nocturne && docker compose ps && echo && echo '--- install log ---' && tail -n 15 /var/log/nocturne-install.log && echo && echo '--- nocturne service ---' && journalctl -u nocturne -n 10 --no-pager && echo && echo '--- last 40 log lines ---' && docker compose logs --tail 40 --no-color"
            if ($null -eq $out) { Fail 'Could not reach the VM through the Azure agent. Is it running?' }
            Write-Host $out
            exit 0
        }
        'Reinstall' {
            Step 'Running the install script on the VM again (keeps .env and data; about 2-10 minutes)'
            # Runs on the VM: Nocturne's install script again, as nocturne-up (which it keeps on the
            # server). A server set up before it existed downloads it first. The instance key is hidden.
            $remote = @'
set -o pipefail
k=$(sed -n 's/^INSTANCE_KEY=//p' /opt/nocturne/.env)
d=$(sed -n 's/^BASE_DOMAIN=//p' /opt/nocturne/.env)
if [ -x /usr/local/sbin/nocturne-up ]; then cmd=/usr/local/sbin/nocturne-up
else curl -fsSL -o /opt/nocturne/install.sh '__INSTALL_URL__' || { echo 'could not download the install script'; exit 1; }; cmd='bash /opt/nocturne/install.sh'; fi
BASE_DOMAIN="$d" DNS_WAIT_MINUTES=10 $cmd < /dev/null 2>&1 | sed "s/$k/[instance key: see your secrets file]/g" > /tmp/nocturne-reinstall.out
code=$?
tail -n 30 /tmp/nocturne-reinstall.out
[ "$code" = 0 ] && echo NOCTURNE_REINSTALL_OK
exit 0
'@
            $out = Invoke-VmShell $remote.Replace('__INSTALL_URL__', $InstallScriptUrl)
            if ($null -eq $out) { Fail 'The VM could not be reached through the Azure agent.' @("Details:  $Self -Action Logs") }
            Write-Host $out
            if ($out -notmatch 'NOCTURNE_REINSTALL_OK') { Fail 'The install script failed on the VM (output above).' @("Details:  $Self -Action Logs") }
            if ($out -match 'did not finish configuring') { Warn 'The install script ran, but the server did not finish configuring (see above).' }
            else { Ok 'Reinstall finished' }
            exit 0
        }
        'Remove' {
            Write-Host "This permanently deletes resource group '$ResourceGroup': the VM, its disk with all Nocturne data, the IP and the network. Billing for them stops." -ForegroundColor Yellow
            $ans = Read-Host 'Type the resource group name to confirm'
            if ($ans -ne $ResourceGroup) { Write-Host 'Cancelled.'; exit 0 }
            Invoke-AzShow group delete -n $ResourceGroup --yes --no-wait
            Ok "Deletion of '$ResourceGroup' started (takes a few minutes)."
            Info "The secrets file is kept: $SecretsFile. Delete it yourself if you won't redeploy."
            exit 0
        }
    }
}

# ================================================================ 3. deploy: inputs
if (-not (Test-Path $Template)) { Fail "Missing file: $Template" }

# The domain: -Domain, else the one this resource group was deployed with, else asked. For a name
# under duckdns.org the script also asks for the DuckDNS token, so the record can be set for you.
Step 'Domain'
$savedDomain = ''
if (Test-Path $SecretsFile) {
    $line = Get-Content $SecretsFile | Where-Object { $_ -match '^CUSTOM_DOMAIN=' } | Select-Object -First 1
    if ($line) { $savedDomain = $line.Substring('CUSTOM_DOMAIN='.Length).Trim() }
}
if (-not $Domain -and $savedDomain) { $Domain = $savedDomain; Ok "Using $Domain (from $SecretsFile)" }
if (-not $Domain) {
    Write-Host '  Nocturne needs a domain whose name and every name under it point at the VM, so each site' -ForegroundColor White
    Write-Host '  gets its own subdomain. Use one you own (e.g. nocturne.example.com), or a free one:' -ForegroundColor White
    Write-Host '  sign in at https://www.duckdns.org, add a name, and enter it here as yourname.duckdns.org.' -ForegroundColor White
    $Domain = Read-Host 'Domain'
}
$Domain = ($Domain -replace '\s', '').ToLowerInvariant()
# At least two labels, not an IP address: the same check as the install script.
if ($Domain -notmatch '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$') {
    Fail "Invalid domain '$Domain'." @('Use a name such as nocturne.example.com or yourname.duckdns.org (no https://).')
}
if ($Domain -like '*.cloudapp.azure.com') {
    Fail "Azure's own names ($Domain) can't have the wildcard record Nocturne needs." @('Use a domain you own, or a free name from https://www.duckdns.org.')
}
$duckName = ''
$duckToken = "$env:DUCKDNS_TOKEN"
if ($Domain -like '*.duckdns.org') {
    # DuckDNS answers every name under yourname.duckdns.org, so one record covers the wildcard too.
    $duckName = ($Domain -replace '\.duckdns\.org$', '').Split('.')[-1]
    if (-not $duckToken) {
        Info 'Paste your DuckDNS token (shown at the top of duckdns.org once signed in) and the record for'
        Info "$duckName.duckdns.org is set for you. Nothing shows as you paste. Or press Enter to set it yourself."
        $secure = Read-Host '    DuckDNS token' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $duckToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $duckToken = $duckToken -replace '\s', ''
    }
    if ($duckToken) {
        if ($duckToken -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { Ok "Read a $($duckToken.Length)-character DuckDNS token" }
        else { Warn 'That is not a DuckDNS token (it looks like 01234567-89ab-cdef-0123-456789abcdef). You can set the record yourself.'; $duckToken = '' }
    }
}
Ok "Nocturne will answer on https://$Domain"

# Points $duckName.duckdns.org at $ip. clear=true first: an IPv6 record left from elsewhere would be
# followed instead of this server.
function Set-DuckDns([string]$ip) {
    foreach ($q in 'clear=true', "ip=$ip") {
        try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri "https://www.duckdns.org/update?domains=$duckName&token=$duckToken&$q" }
        catch { return $false }
        if ("$($r.Content)" -notmatch '^OK') { return $false }
    }
    return $true
}
function Get-ARecords([string]$name) {
    @(Resolve-DnsName $name -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
}

Step 'Your public IP (SSH is only allowed from here)'
$myIp = $null
try { $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).ToString().Trim() } catch {}
if ($myIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $myIp = Read-Host 'Could not detect it. Enter your public IPv4 address' }
Ok $myIp

Step 'SSH key'
if (-not (Test-Path "$SshKeyPath.pub")) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SshKeyPath) | Out-Null
    Info "Creating a key at $SshKeyPath (press Enter twice for no passphrase, or type one)."
    & ssh-keygen -t ed25519 -f $SshKeyPath -C 'nocturne-azure'
    if (-not (Test-Path "$SshKeyPath.pub")) { Fail 'SSH key was not created.' }
}
$sshPublicKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()
Ok "Using $SshKeyPath.pub"

# ================================================================ 3. deploy: size and cost
Step 'Region'
$regionChosenHere = $false
$existingRg = & $script:AzExe group show -n $ResourceGroup --query location -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existingRg) {
    # A resource group (and the VM in it) can't move regions: re-runs stay where they are.
    if ($Location -and $Location -ne $existingRg) {
        Warn "Resource group '$ResourceGroup' already exists in $existingRg, so that region is used."
        Warn 'For a new deployment somewhere else, pass a different -ResourceGroup.'
    }
    $Location = $existingRg.Trim()
    Ok "Using $Location (where '$ResourceGroup' already is)"
} elseif ($Location) {
    Ok "Using $Location (from -Location)"
} else {
    $Location = Select-Region
    $regionChosenHere = $true
    Ok "Region: $Location"
}

Step "VM sizes your subscription can use in $Location"
while ($true) {
    $avail = Get-AvailableSizes
    $cands = @($avail.Candidates)
    Ok "$($cands.Count) sizes are available to your subscription in $Location"
    foreach ($k in ($avail.Skipped.Keys | Sort-Object)) { Info "skipped $($avail.Skipped[$k]): $k" }
    if ($cands.Count -gt 0) { break }
    if (-not $regionChosenHere) {
        Fail "No usable VM sizes for your subscription in $Location." @(
            'Run without -Location to choose another region (sorted by price).',
            'Or request more vCPU quota: Azure portal > Quotas > Compute.')
    }
    Warn "No usable VM sizes for your subscription in $Location (it may need special access, or your quota there is 0). Please pick another region."
    $Location = Select-Region
    Ok "Region: $Location"
}

Step "VM size and estimated cost ($Location, live list prices)"

Info 'Looking up prices for the small sizes...'
$ipHourly = Get-IpHourly
$disk = Get-DiskMonthly $OsDiskGb
# Price only what the menu can show (up to 16 GB, 4 vCPUs), plus a size named with -VmSize.
$toPrice = @($cands | Where-Object { $_.MemGB -le 16 -and $_.Cpu -le 4 } | ForEach-Object { $_.Size })
if ($VmSize) { $toPrice += $VmSize }
$prices = Get-VmPrices @($toPrice | Sort-Object -Unique)
foreach ($c in $cands) { if ($prices.ContainsKey($c.Size)) { $c.Hourly = $prices[$c.Size] } }
$fixedMonthly = $null
if ($null -ne $disk.Price -and $null -ne $ipHourly) { $fixedMonthly = $disk.Price + $ipHourly * $HoursPerMonth }

if ($VmSize) {
    $chosen = $cands | Where-Object { $_.Size -eq $VmSize } | Select-Object -First 1
    if (-not $chosen) {
        Fail "$VmSize is not available to your subscription in $Location (restricted, out of quota, or not offered)." @(
            'Run without -VmSize to choose from the sizes you can use.')
    }
} else {
    $rows = @(Select-CheapestTiers $cands $MemoryTiers)
    if ($rows.Count -eq 0) { Fail "Could not get prices for any usable size in $Location." @('Try again later, or pass -VmSize.') }
    Write-Host ''
    Write-Host '  Cheapest sizes available to YOUR subscription, by memory (estimates, per month):' -ForegroundColor White
    Write-Host ('  {0,-3} {1,-9} {2,-20} {3,-12} {4,6} {5,10} {6,11}   {7}' -f '#', 'Tier', 'Size', 'CPU', 'RAM', 'VM', 'Total*', '')
    $i = 0; $default = 1
    foreach ($r in $rows) {
        $i++
        $tierLabel = (($r.Tiers | ForEach-Object { "$_" }) -join '/') + ' GB'
        $vmM = $r.Hourly * $HoursPerMonth
        $tot = if ($null -ne $fixedMonthly) { $vmM + $fixedMonthly } else { $null }
        $note = ''
        if ($r.Tiers -contains 4) { $note = 'recommended'; $default = $i }
        elseif ($r.Tiers -contains 2 -and $r.MemGB -lt 4) { $note = 'minimum spec: can feel slow' }
        else { $note = 'more headroom' }
        Write-Host ('  {0,-3} {1,-9} {2,-20} {3,-12} {4,6} {5,10} {6,11}   {7}' -f $i, $tierLabel, $r.Size, "$($r.Cpu) vCPU $($r.Arch)", "$($r.MemGB) GB", (Format-Usd $vmM), (Format-Usd $tot), $note)
    }
    Write-Host '  * Total = VM + disk + static IP. List prices; your bill can differ.' -ForegroundColor DarkGray
    Write-Host ''
    $pick = Read-Host "Choose a size [1-$($rows.Count), Enter = $default]"
    if (-not $pick) { $pick = "$default" }
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $rows.Count) { Fail "Invalid choice '$pick'." }
    $chosen = $rows[[int]$pick - 1]
    $VmSize = $chosen.Size
}
$vmHourly = $chosen.Hourly
Ok "$VmSize ($($chosen.Cpu) vCPU $($chosen.Arch), $($chosen.MemGB) GB) is available to your subscription"
if ($chosen.MemGB -lt 2) { Warn 'Less than 2 GB RAM: below Nocturne''s minimum.' }

$vmMonthly = if ($null -ne $vmHourly) { $vmHourly * $HoursPerMonth } else { $null }
$ipMonthly = if ($null -ne $ipHourly) { $ipHourly * $HoursPerMonth } else { $null }
$parts = @($vmMonthly, $disk.Price, $ipMonthly)
$total = if (@($parts | Where-Object { $null -eq $_ }).Count -eq 0) { ($parts | Measure-Object -Sum).Sum } else { $null }

Write-Host ''
Write-Host '  ESTIMATED cost of running Nocturne 24/7 (USD, pay-as-you-go list prices)' -ForegroundColor Yellow
Write-Host ('    VM {0,-32} {1,10} /month' -f "$VmSize (Linux)", (Format-Usd $vmMonthly))
Write-Host ('    OS disk {0,-27} {1,10} /month' -f "$OsDiskGb GB Standard SSD ($($disk.Tier))", (Format-Usd $disk.Price))
Write-Host ('    {0,-35} {1,10} /month' -f 'Static public IP', (Format-Usd $ipMonthly))
Write-Host  '    ----------------------------------------------------'
if ($null -ne $total) {
    Write-Host ('    {0,-35} {1,10} /month  (about {2} per day)' -f 'Total (estimate)', (Format-Usd $total), (Format-Usd ($total / 30.4))) -ForegroundColor Yellow
} else {
    Write-Host '    Total: could not get every price from Azure. See https://azure.microsoft.com/pricing/calculator/' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  This is ONLY AN ESTIMATE. Your actual bill can differ: it uses list prices for' -ForegroundColor Yellow
Write-Host "  $Location at $HoursPerMonth hours a month, and does not include data transfer beyond the free" -ForegroundColor Yellow
Write-Host '  allowance, disk transactions, backups or taxes, or any discounts, credits or currency' -ForegroundColor Yellow
Write-Host '  conversion on your account. Check your costs in the Azure portal (Cost Management).' -ForegroundColor Yellow
Write-Host "  The VM bills until you remove it:  $Self -Action Remove" -ForegroundColor Yellow
Write-Host ''
if ($Yes) {
    Info '-Yes given: continuing without asking.'
} else {
    $ans = Read-Host 'Create the VM and start billing? (Y/N)'
    if ($ans -notmatch '^[Yy]') { Write-Host 'Cancelled. Nothing was created.'; exit 0 }
}

# ================================================================ 3. deploy: secrets
Step 'Secrets'
$secrets = [ordered]@{}
if (Test-Path $SecretsFile) {
    foreach ($line in Get-Content $SecretsFile) {
        if ($line -match '^\s*([A-Z_]+)=(.*)$') { $secrets[$Matches[1]] = $Matches[2] }
    }
    Ok "Reusing secrets from $SecretsFile (the database was created with these)"
    if ($secrets.Contains('CUSTOM_DOMAIN') -and $secrets['CUSTOM_DOMAIN'] -ne $Domain) {
        Warn "The first deployment used domain '$($secrets['CUSTOM_DOMAIN'])' but this run uses '$Domain'."
        Warn "The VM keeps the domain it was set up with. To change it, SSH in and run: sudo BASE_DOMAIN=$Domain nocturne-up"
    }
} else {
    $secrets['INSTANCE_KEY'] = New-Secret 64
    $secrets['POSTGRES_PASSWORD'] = New-Secret 40
    $secrets['POSTGRES_APP_PASSWORD'] = New-Secret 40
    $secrets['POSTGRES_MIGRATOR_PASSWORD'] = New-Secret 40
    $secrets['POSTGRES_WEB_PASSWORD'] = New-Secret 40
    $secrets['CUSTOM_DOMAIN'] = $Domain
    New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
    @('# Nocturne on Azure: secrets for resource group ' + $ResourceGroup,
      '# Keep a copy somewhere safe. Losing INSTANCE_KEY makes stored connector secrets unreadable.') +
        @($secrets.Keys | ForEach-Object { "$_=$($secrets[$_])" }) | Set-Content -Path $SecretsFile -Encoding ASCII
    Ok "Generated new secrets and saved them to $SecretsFile (not shown)"
    Warn 'Back that file up somewhere other than this PC.'
}

# ================================================================ 4. deploy: Azure resources
Step "Resource group $ResourceGroup in $Location"
Invoke-AzShow group create -n $ResourceGroup -l $Location --output table

Step "Creating the VM and network with Bicep ($VmSize, Ubuntu 24.04) - about 3-5 minutes"
# Image and security settings follow what Azure reports for the chosen size.
$imageSku = 'server'
if ($chosen.Arch -eq 'Arm64') { $imageSku = 'server-arm64' }
# Secure values go in a temporary parameters file, never on the command line.
$params = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        name                     = @{ value = $Name }
        vmSize                   = @{ value = $VmSize }
        imageSku                 = @{ value = $imageSku }
        trustedLaunch            = @{ value = [bool]$chosen.TrustedLaunch }
        osDiskSizeGb             = @{ value = $OsDiskGb }
        sshPublicKey             = @{ value = $sshPublicKey }
        sshAllowedCidr           = @{ value = "$myIp/32" }
        domain                   = @{ value = $Domain }
        instanceKey              = @{ value = $secrets['INSTANCE_KEY'] }
        postgresPassword         = @{ value = $secrets['POSTGRES_PASSWORD'] }
        postgresAppPassword      = @{ value = $secrets['POSTGRES_APP_PASSWORD'] }
        postgresMigratorPassword = @{ value = $secrets['POSTGRES_MIGRATOR_PASSWORD'] }
        postgresWebPassword      = @{ value = $secrets['POSTGRES_WEB_PASSWORD'] }
    }
}
$paramFile = Join-Path $env:TEMP "nocturne-params-$PID.json"
$params | ConvertTo-Json -Depth 5 | Set-Content -Path $paramFile -Encoding ASCII
try {
    Invoke-AzShow deployment group create -g $ResourceGroup -n $Deployment --template-file $Template --parameters "@$paramFile" --query 'properties.provisioningState' --output tsv
} finally {
    Remove-Item $paramFile -ErrorAction SilentlyContinue
}
$o = Get-DeploymentOutputs
if (-not $o) { Fail 'Deployment finished but its outputs could not be read.' }
Ok "VM is up at $($o.Ip) ($($o.AzureFqdn))"

# Sets or shows the DNS records, then waits until the name and a name under it resolve to the VM.
Step "DNS for $($o.BaseDomain)"
$manualDns = $true
if ($duckName -and $duckToken) {
    if (Set-DuckDns $o.Ip) { Ok "$duckName.duckdns.org now points at $($o.Ip)"; $manualDns = $false }
    else { Warn "DuckDNS refused the update. Check the token, and that $duckName is listed under your domains there." }
}
if ($manualDns) {
    if ($duckName) {
        Write-Host "  At https://www.duckdns.org, set the current ip of $duckName to $($o.Ip) and select update ip." -ForegroundColor Yellow
    } else {
        Write-Host '  Create these two records at your DNS provider (do not proxy them through Cloudflare):' -ForegroundColor Yellow
        Write-Host "    A   $($o.BaseDomain)      ->  $($o.Ip)"
        Write-Host "    A   *.$($o.BaseDomain)    ->  $($o.Ip)      (each site's subdomain, and share links)"
    }
}
Info 'Waiting until the domain resolves to the VM (checks every 20s)...'
$until = (Get-Date).AddMinutes($TimeoutMinutes)
while ($true) {
    $apex = Get-ARecords $o.BaseDomain
    $sub = Get-ARecords "dns-check.$($o.BaseDomain)"
    if (($apex -contains $o.Ip) -and ($sub -contains $o.Ip)) { Ok "$($o.BaseDomain) and *.$($o.BaseDomain) resolve to $($o.Ip)"; break }
    if ((Get-Date) -gt $until) {
        Fail "DNS for $($o.BaseDomain) still doesn't point to $($o.Ip)." @(
            'Set the records above, then run the same command again (re-runs are safe). Nocturne starts by itself once DNS works.')
    }
    Info "...not yet ($($o.BaseDomain): $(if ($apex) { $apex -join ', ' } else { 'no record' }); *.$($o.BaseDomain): $(if ($sub) { $sub -join ', ' } else { 'no record' }))"
    Start-Sleep 20
}

# ================================================================ 5. install runs on the VM; follow it
Step "Nocturne's install script is running on the VM (Docker, then the release) - about 5-10 minutes"
$until = (Get-Date).AddMinutes($TimeoutMinutes)
$lastLine = ''
while ($true) {
    # The install script colours its output; the escapes are removed on the VM.
    $out = Invoke-VmShell 'if [ -f /var/log/nocturne-install.log ]; then tail -n 3 /var/log/nocturne-install.log | sed "s/\x1b\[[0-9;]*m//g"; else echo "(waiting for first-boot setup to start)"; fi; cloud-init status 2>/dev/null | tail -n 1'
    if ($out) {
        $lines = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $newest = ($lines | Where-Object { $_ -notmatch '^status:' } | Select-Object -Last 1)
        if ($newest -and $newest -ne $lastLine) { Info "VM: $newest"; $lastLine = $newest } else { Info '...still working' }
        if ($out -match 'NOCTURNE_INSTALL_DONE') { Ok 'The install script finished'; break }
        if ($out -match 'NOCTURNE_INSTALL_FAILED' -or $out -match 'status: error') {
            Fail 'The install script failed on the VM.' @("Details:  $Self -Action Logs",
                "After fixing:  $Self -Action Reinstall")
        }
    } else {
        Info '...VM agent not answering yet'
    }
    if ((Get-Date) -gt $until) { Fail "Setup did not finish in $TimeoutMinutes minutes." @("Check:  $Self -Action Logs") }
    Start-Sleep 15
}

# ================================================================ 6. check HTTPS
Step "Waiting for https://$($o.BaseDomain) (Caddy gets the Let's Encrypt certificate on first start)"
$until = (Get-Date).AddMinutes(10)
while ($true) {
    $status = $null
    try { $status = (Invoke-WebRequest -Uri "https://$($o.BaseDomain)/" -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5).StatusCode }
    catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        else { Info "...not ready yet ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" }
    }
    if ($status -and $status -lt 500) { Ok "Nocturne answered with HTTP $status"; break }
    if ($status) { Info "...HTTP $status, services still starting" }
    if ((Get-Date) -gt $until) {
        Warn 'Nocturne did not answer over HTTPS within 10 minutes. It may still be starting.'
        Info "Check:  $Self -Action Logs"
        break
    }
    Start-Sleep 15
}

Step 'Nocturne is deployed'
Show-Info $o
Write-Host ''
$setupUrl = "https://$($o.BaseDomain)/setup"
Write-Host "  Next: finish the first-run setup (create the owner account) at  $setupUrl" -ForegroundColor Cyan
if ($null -ne $total) { Write-Host "  Estimated running cost: about $(Format-Usd $total) a month (estimate only)." -ForegroundColor Cyan }
Write-Host "  Remove everything (stops billing):  $Self -Action Remove" -ForegroundColor Cyan
$ans = Read-Host 'Open the setup page in your browser now? (Y/N)'
if ($ans -match '^[Yy]') { Start-Process $setupUrl }
