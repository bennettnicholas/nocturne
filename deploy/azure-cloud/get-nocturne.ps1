# get-nocturne.ps1 - one-line installer for Windows.
#
#   irm https://raw.githubusercontent.com/bennettnicholas/nocturne/azure-cloud-deploymentscripts/deploy/azure-cloud/get-nocturne.ps1 | iex
#
# With options (passed to Deploy-NocturneAzure.ps1):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/bennettnicholas/nocturne/azure-cloud-deploymentscripts/deploy/azure-cloud/get-nocturne.ps1))) -TenantId <tenant-id>
#
# Downloads the toolkit files from GitHub into %USERPROFILE%\nocturne-azure (an update keeps your
# secrets\ folder), then runs Deploy-NocturneAzure.ps1. Re-run it any time to update and deploy again.
#
# A branch build: Publish-BranchImages.ps1 writes %USERPROFILE%\nocturne-azure\branch.env, and this
# script then downloads that branch's toolkit and deploys that branch's images (environment
# variables still win). Publish-BranchImages.ps1 -Official switches back to the release.
#
# Where the toolkit is published (override with environment variables for testing):
param([Parameter(ValueFromRemainingArguments = $true)] $DeployArgs)

$Dest    = Join-Path $HOME 'nocturne-azure'
if ($env:NOCTURNE_TOOLS_DIR) { $Dest = $env:NOCTURNE_TOOLS_DIR }

$BranchSettings = @{}
$BranchFile = Join-Path $Dest 'branch.env'
if (Test-Path $BranchFile) {
    foreach ($line in Get-Content $BranchFile) {
        if ($line -match '^\s*(NOCTURNE_[A-Z_]+)=(.*)$') { $BranchSettings[$Matches[1]] = $Matches[2].Trim() }
    }
}
function Get-Setting([string]$key) {
    $v = [Environment]::GetEnvironmentVariable($key)
    if ($v) { return $v }
    return $BranchSettings[$key]
}

$Repo    = 'bennettnicholas/nocturne'
$Branch  = 'azure-cloud-deploymentscripts'   # or a release tag for a fixed version
$Folder  = 'deploy/azure-cloud'               # the toolkit's folder in the repository
if (Get-Setting 'NOCTURNE_TOOLS_REPO')   { $Repo = Get-Setting 'NOCTURNE_TOOLS_REPO' }
if (Get-Setting 'NOCTURNE_TOOLS_BRANCH') { $Branch = Get-Setting 'NOCTURNE_TOOLS_BRANCH' }
$BaseUrl = "https://raw.githubusercontent.com/$Repo/$Branch/$Folder"
if ($env:NOCTURNE_TOOLS_BASE_URL) { $BaseUrl = $env:NOCTURNE_TOOLS_BASE_URL }

# Passed to Deploy-NocturneAzure.ps1 through its environment.
$ImageSettings = @{}
foreach ($key in 'NOCTURNE_API_IMAGE', 'NOCTURNE_WEB_IMAGE', 'NOCTURNE_OFFICIAL_IMAGES') {
    $v = Get-Setting $key
    if ($v) { $ImageSettings[$key] = $v }
}

# The toolkit: only these files are downloaded, not the whole repository.
$Files = @(
    'Deploy-NocturneAzure.ps1',
    'deploy-nocturne-azure.sh',
    'install-nocturne.sh',
    'infra/nocturne-vm.bicep'
)

# This runs inside the user's own PowerShell window (irm | iex): never call `exit` here, it
# would close their window. Errors stop this script only.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'      # the progress bar makes downloads very slow in PowerShell 5.1
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    if ($BranchSettings.Count -gt 0) {
        Write-Host "==> Using $BranchFile" -ForegroundColor Cyan
        if ($ImageSettings['NOCTURNE_API_IMAGE']) {
            Write-Host "    Images: $($ImageSettings['NOCTURNE_API_IMAGE']), $($ImageSettings['NOCTURNE_WEB_IMAGE'])" -ForegroundColor Gray
        }
    }
    Write-Host "==> Downloading the Nocturne deploy toolkit ($Repo, $Branch)" -ForegroundColor Cyan
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nocturne-get-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        # Everything is downloaded before anything is copied, so a failed download leaves the
        # old toolkit as it was.
        foreach ($file in $Files) {
            $url = "$BaseUrl/$file"
            $out = Join-Path $tmp ($file -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
            try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing }
            catch { throw "Could not download $url ($($_.Exception.Message))" }
        }
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        # Copy over the old version; secrets\ and logs\ are not in the download, so they are kept.
        Copy-Item -Path (Join-Path $tmp '*') -Destination $Dest -Recurse -Force
        Write-Host "    Toolkit is in $Dest" -ForegroundColor Green
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    Write-Host '==> Starting Deploy-NocturneAzure.ps1' -ForegroundColor Cyan
    # A separate process with -ExecutionPolicy Bypass: works without changing the PC's policy.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dest 'Deploy-NocturneAzure.ps1')) + @($DeployArgs | Where-Object { $null -ne $_ })
    # The deploy script prints this command (with an action) for later, so it shows this address.
    $getUrl = "$BaseUrl/get-nocturne.ps1"
    $childEnv = @{ NOCTURNE_GET_URL = $getUrl } + $ImageSettings
    $before = @{}
    foreach ($key in $childEnv.Keys) {
        $before[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $childEnv[$key])
    }
    try { & powershell.exe @argList }
    finally { foreach ($key in $before.Keys) { [Environment]::SetEnvironmentVariable($key, $before[$key]) } }
    Write-Host ''
    Write-Host "Run it again later:  irm $getUrl | iex" -ForegroundColor Gray
}
