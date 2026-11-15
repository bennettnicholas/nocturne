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
      5. Delivers install-nocturne.sh to the VM and runs it automatically on first boot. That
         installer is cloud-agnostic: it works on any Ubuntu/Debian server.
      6. Follows the install from here, then checks Nocturne answers over HTTPS.

    Nocturne runs from its official Docker Compose release bundle: PostgreSQL, API, web app,
    gateway, Caddy (automatic HTTPS) and Watchtower (automatic updates). This is a real instance,
    not the Aspire dev environment that Deploy-Nocturne.ps1 sets up.

    Re-running Deploy when the VM already exists (and its first install finished) updates it in
    place: the installer runs again with the images below, and .env and the data are kept.

    Images: -ApiImage and -WebImage (or NOCTURNE_API_IMAGE / NOCTURNE_WEB_IMAGE, which
    get-nocturne.ps1 sets from branch.env, written by Publish-BranchImages.ps1) run a branch build
    instead of the release. -OfficialImages goes back to the release's images.

    Address:
      - No -Domain: the free Azure name https://<name>-<hash>.<region>.cloudapp.azure.com
        (one tenant at the root; Azure DNS names cannot have tenant subdomains).
      - -Domain nocturne.example.com: your own domain; the script lists the two DNS records to create.

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
    .\Deploy-NocturneAzure.ps1 -Action Reinstall   # upload the current install-nocturne.sh and re-run it
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -ApiImage ghcr.io/me/nocturne/nocturne-api:branch-feature-x -WebImage ghcr.io/me/nocturne/nocturne-web:branch-feature-x
.EXAMPLE
    .\Deploy-NocturneAzure.ps1 -OfficialImages     # back to the release's images
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
    [int]$TimeoutMinutes = 30,
    [string]$ApiImage = '',               # empty = NOCTURNE_API_IMAGE, else the release's
    [string]$WebImage = '',               # empty = NOCTURNE_WEB_IMAGE, else the release's
    [switch]$OfficialImages
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
$Installer   = Join-Path $PSScriptRoot 'install-nocturne.sh'
$SecretsDir  = Join-Path $PSScriptRoot 'secrets'
$SecretsFile = Join-Path $SecretsDir "$ResourceGroup.env"
# The commands this script prints for later (remove, logs, ...) are the one-line installer from
# GitHub with an action, so they work on any computer, from any folder. get-nocturne.ps1 passes
# its own address, so a fork or another branch prints its own.
$GetUrl      = 'https://raw.githubusercontent.com/bennettnicholas/nocturne/azure-cloud-deploymentscripts/deploy/azure-cloud/get-nocturne.ps1'
if ($env:NOCTURNE_GET_URL) { $GetUrl = $env:NOCTURNE_GET_URL }
$GetCommand  = "irm $GetUrl | iex"
$Self        = "& ([scriptblock]::Create((irm $GetUrl)))"
$Deployment  = 'nocturne'
$VmName      = "$Name-vm"

# The images to run, and the installer options that select them. No images = the installer keeps
# whatever the VM's .env has (on a new VM, the release's).
if (-not $ApiImage -and $env:NOCTURNE_API_IMAGE) { $ApiImage = $env:NOCTURNE_API_IMAGE }
if (-not $WebImage -and $env:NOCTURNE_WEB_IMAGE) { $WebImage = $env:NOCTURNE_WEB_IMAGE }
if (-not $ApiImage -and $env:NOCTURNE_OFFICIAL_IMAGES -eq '1') { $OfficialImages = $true }
if ($OfficialImages) { $ApiImage = ''; $WebImage = '' }
$ImagePattern = '^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?(:[A-Za-z0-9_.-]{1,128}|@sha256:[a-f0-9]{64})$'
if ([bool]$ApiImage -ne [bool]$WebImage) { Fail 'Give -ApiImage and -WebImage together.' }
foreach ($img in @($ApiImage, $WebImage)) {
    if ($img -and $img -cnotmatch $ImagePattern) { Fail "Not an image reference: $img" }
}
$InstallerImageArgs = ''
if ($OfficialImages) { $InstallerImageArgs = ' --official-images' }
elseif ($ApiImage) { $InstallerImageArgs = " --api-image $ApiImage --web-image $WebImage" }

# Uploads the current install-nocturne.sh to the VM and runs it with the image options. Keeps .env
# and the data. Returns the installer's last lines, or $null when the VM could not be reached.
function Invoke-Reinstall {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Installer))
    return Invoke-VmShell "echo '$b64' | base64 -d > /opt/nocturne/install-nocturne.sh && chmod 700 /opt/nocturne/install-nocturne.sh && /opt/nocturne/install-nocturne.sh$InstallerImageArgs > /tmp/nocturne-reinstall.out 2>&1; code=`$?; tail -n 25 /tmp/nocturne-reinstall.out; exit `$code"
}

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
        User = $o.adminUsername.value; CustomDomain = $o.usesCustomDomain.value
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
Step 'Checking Azure sign-in'
& $script:AzExe account show --output table
$signedIn = ($LASTEXITCODE -eq 0)
if ($signedIn -and $TenantId) {
    $current = & $script:AzExe account show --query tenantId -o tsv 2>$null
    if ($current -ne $TenantId) { Info "Switching directory to $TenantId."; $signedIn = $false }
}
if (-not $signedIn) {
    $loginArgs = @('login')
    if ($TenantId)   { $loginArgs += @('--tenant', $TenantId) }
    if ($DeviceCode) { $loginArgs += '--use-device-code' }
    Step 'Signing in to Azure (complete MFA and pick your subscription if asked)'
    Show-AzCommand $loginArgs
    & $script:AzExe @loginArgs
    if ($LASTEXITCODE -ne 0) { Fail 'az login failed (see the Azure output above).' }
}
& $script:AzExe account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Fail 'Signed in, but no Azure subscription is available.' @(
        'If Azure said you must use multi-factor authentication (AADSTS50076), re-run with -TenantId <tenant-id>.',
        'Add -DeviceCode if the MFA prompt does not appear.')
}
$sub = Invoke-AzRead account show --query '{name:name, tenant:tenantId}' --output json | ConvertFrom-Json
Ok "Subscription: $($sub.name)"

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
            $out = Invoke-VmShell "cd /opt/nocturne && docker compose ps && echo && echo '--- install log ---' && tail -n 15 /var/log/nocturne-install.log && echo && echo '--- last 40 log lines ---' && docker compose logs --tail 40 --no-color"
            if ($null -eq $out) { Fail 'Could not reach the VM through the Azure agent. Is it running?' }
            Write-Host $out
            exit 0
        }
        'Reinstall' {
            Step 'Uploading install-nocturne.sh to the VM and re-running it (keeps .env and data)'
            $out = Invoke-Reinstall
            if ($null -eq $out) { Fail 'The installer failed or the VM could not be reached.' @("Details:  $Self -Action Logs") }
            Write-Host $out
            if ($out -match 'NOCTURNE_INSTALL_DONE') { Ok 'Reinstall finished' } else { Fail 'Reinstall did not finish (output above).' }
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
foreach ($f in $Template, $Installer) { if (-not (Test-Path $f)) { Fail "Missing file: $f" } }
# The installer runs on Linux: make sure it has Unix line endings (an editor may have changed them).
$installerText = [IO.File]::ReadAllText($Installer)
if ($installerText.Contains("`r")) {
    [IO.File]::WriteAllText($Installer, $installerText.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    Info 'Converted install-nocturne.sh to Unix line endings'
}

if ($ApiImage) { Info "Images: $ApiImage, $WebImage" }
elseif ($OfficialImages) { Info "Images: the release's" }

# An existing VM whose first install finished is updated in place: custom data only runs on first
# boot, so re-applying the template would change nothing on it.
$existing = Get-DeploymentOutputs
if ($existing) {
    Step "Nocturne is already deployed in '$ResourceGroup': checking its install"
    $done = Invoke-VmShell 'grep -c NOCTURNE_INSTALL_DONE /var/log/nocturne-install.log 2>/dev/null || echo 0'
    if ($done -match '^\s*[1-9]') {
        Step 'Updating Nocturne on the VM (keeps .env and data) - a few minutes'
        $out = Invoke-Reinstall
        if ($null -eq $out) { Fail 'The update failed or the VM could not be reached.' @("Details:  $Self -Action Logs") }
        Write-Host $out
        if ($out -notmatch 'NOCTURNE_INSTALL_DONE') { Fail 'The update did not finish (output above).' @("Details:  $Self -Action Logs") }
        Ok 'Nocturne is updated'
        Show-Info $existing
        Write-Host ''
        Write-Host "  For a new VM instead, remove this one first:  $Self -Action Remove" -ForegroundColor Gray
        exit 0
    }
    Warn 'The first install has not finished on this VM, so the normal deploy continues.'
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
        Warn 'The VM keeps its first .env. To change the domain, edit BASE_DOMAIN in /opt/nocturne/.env over SSH and run: docker compose up -d'
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
        customDomain             = @{ value = $Domain }
        instanceKey              = @{ value = $secrets['INSTANCE_KEY'] }
        postgresPassword         = @{ value = $secrets['POSTGRES_PASSWORD'] }
        postgresAppPassword      = @{ value = $secrets['POSTGRES_APP_PASSWORD'] }
        postgresMigratorPassword = @{ value = $secrets['POSTGRES_MIGRATOR_PASSWORD'] }
        postgresWebPassword      = @{ value = $secrets['POSTGRES_WEB_PASSWORD'] }
        apiImage                 = @{ value = $ApiImage }
        webImage                 = @{ value = $WebImage }
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

if ($o.CustomDomain) {
    Step "DNS for $($o.BaseDomain)"
    Write-Host '  Create these two records at your DNS provider:' -ForegroundColor Yellow
    Write-Host "    A   $($o.BaseDomain)      ->  $($o.Ip)"
    Write-Host "    A   *.$($o.BaseDomain)    ->  $($o.Ip)      (tenant subdomains and share links)"
    Info 'Waiting until the domain resolves to the VM (checks every 20s; create the records now)...'
    $until = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $resolved = @(Resolve-DnsName $o.BaseDomain -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($resolved -contains $o.Ip) { Ok "$($o.BaseDomain) resolves to $($o.Ip)"; break }
        if ((Get-Date) -gt $until) { Fail "DNS for $($o.BaseDomain) still doesn't point to $($o.Ip)." @('Create the records above, then re-run (re-runs are safe).') }
        Info "...not yet (currently: $(if ($resolved) { $resolved -join ', ' } else { 'no record' }))"
        Start-Sleep 20
    }
}

# ================================================================ 5. install runs on the VM; follow it
Step 'install-nocturne.sh is running on the VM (Docker, then the release bundle) - about 5-10 minutes'
$until = (Get-Date).AddMinutes($TimeoutMinutes)
$lastLine = ''
while ($true) {
    $out = Invoke-VmShell 'tail -n 3 /var/log/nocturne-install.log 2>/dev/null || echo "(waiting for first-boot setup to start)"; cloud-init status 2>/dev/null | tail -n 1'
    if ($out) {
        $lines = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $newest = ($lines | Where-Object { $_ -notmatch '^status:' } | Select-Object -Last 1)
        if ($newest -and $newest -ne $lastLine) { Info "VM: $newest"; $lastLine = $newest } else { Info '...still working' }
        if ($out -match 'NOCTURNE_INSTALL_DONE') { Ok 'install-nocturne.sh finished: containers are running'; break }
        if ($out -match 'ERROR:' -or $out -match 'status: error') {
            Fail 'install-nocturne.sh failed on the VM.' @("Details:  $Self -Action Logs",
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
