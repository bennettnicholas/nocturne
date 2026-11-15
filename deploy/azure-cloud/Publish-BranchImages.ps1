<#
.SYNOPSIS
    Publishes this repository's current branch as Docker images and points the Azure toolkit at them.

.DESCRIPTION
    Run it from your clone, on the branch you want to test:
      1. Pushes the branch to GitHub (origin).
      2. Waits for the "Branch images" workflow (.github/workflows/branch-images.yml) to build the
         API and web images for that commit. It runs for every push to a feature/... branch.
      3. Checks the images can be downloaded without signing in (the VM pulls them anonymously).
      4. Writes %USERPROFILE%\nocturne-azure\branch.env, which get-nocturne.ps1 reads: it then
         downloads this branch's toolkit and deploys this branch's images. On a VM that is already
         deployed, that is an update in place: .env and the data are kept.

    Then re-run get-nocturne.ps1 (the command is printed at the end, and offered to run).

    The images are tagged branch-<branch name>, a tag that moves with every push, so a VM on it
    also picks up later pushes through Watchtower (once a day). Re-run this script and then
    get-nocturne.ps1 to update at once.

.EXAMPLE
    .\deploy\azure-cloud\Publish-BranchImages.ps1
.EXAMPLE
    .\deploy\azure-cloud\Publish-BranchImages.ps1 -Official     # next get-nocturne run goes back to the release
#>
[CmdletBinding()]
param(
    [switch]$Official,          # switch the toolkit back to the release's images
    [switch]$NoPush,            # the branch is already pushed: only wait for its images
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Info([string]$m) { Write-Host "       $m" -ForegroundColor Gray }
function Fail([string]$m, [string[]]$hints = @()) {
    Write-Host "[FAILED] $m" -ForegroundColor Red
    foreach ($h in $hints) { Write-Host "  - $h" -ForegroundColor Yellow }
    exit 1
}

$ToolkitDir = Join-Path $HOME 'nocturne-azure'
if ($env:NOCTURNE_TOOLS_DIR) { $ToolkitDir = $env:NOCTURNE_TOOLS_DIR }
$BranchFile = Join-Path $ToolkitDir 'branch.env'
$WorkflowName = 'Branch images'

function Invoke-Git {
    # Continue: under Stop, PowerShell 5.1 turns any redirected stderr line into a terminating error.
    $ErrorActionPreference = 'Continue'
    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "git $($args -join ' ') failed:`n$($out | Out-String)" }
    return ($out | Out-String).Trim()
}

function Read-BranchFile {
    $settings = [ordered]@{}
    if (Test-Path $BranchFile) {
        foreach ($line in Get-Content $BranchFile) {
            if ($line -match '^\s*(NOCTURNE_[A-Z_]+)=(.*)$') { $settings[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $settings
}

function Write-BranchFile($settings, [string]$comment) {
    New-Item -ItemType Directory -Force -Path $ToolkitDir | Out-Null
    $lines = @("# $comment", '# Read by get-nocturne.ps1. Written by Publish-BranchImages.ps1.')
    foreach ($k in $settings.Keys) { $lines += "$k=$($settings[$k])" }
    $lines | Set-Content -Path $BranchFile -Encoding ASCII
}

function Get-GetCommand([string]$repo, [string]$branch) {
    return "irm https://raw.githubusercontent.com/$repo/$branch/deploy/azure-cloud/get-nocturne.ps1 | iex"
}

function Offer-Run([string]$command) {
    Write-Host ''
    Write-Host "  Next, run:  $command" -ForegroundColor Cyan
    $ans = Read-Host 'Run it now? (Y/N)'
    if ($ans -match '^[Yy]') { Invoke-Expression $command }
}

# The same slug the workflow computes for the branch tag.
function Get-BranchTag([string]$branch) {
    $slug = $branch.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 100) { $slug = $slug.Substring(0, 100) }
    return "branch-$slug"
}

# GitHub's REST API, anonymous unless GITHUB_TOKEN is set (anonymous is limited to 60 calls an hour).
function Invoke-GitHub([string]$path) {
    $headers = @{ 'User-Agent' = 'nocturne-publish-branch-images'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    return Invoke-RestMethod -Uri "https://api.github.com$path" -Headers $headers -TimeoutSec 30
}

# Whether the VM can pull image REPO:TAG from ghcr.io without signing in.
function Test-AnonymousPull([string]$repository, [string]$tag) {
    try {
        $token = (Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:${repository}:pull" -TimeoutSec 30).token
        $headers = @{
            Authorization = "Bearer $token"
            Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
        }
        $null = Invoke-WebRequest -Method Head -Uri "https://ghcr.io/v2/$repository/manifests/$tag" -Headers $headers -UseBasicParsing -TimeoutSec 30
        return $true
    } catch {
        return $false
    }
}

# ================================================================ where we are
Step 'Repository and branch'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git is not installed.' }
$root = Invoke-Git -C $PSScriptRoot rev-parse --show-toplevel
$branch = Invoke-Git -C $root branch --show-current
if (-not $branch) { Fail 'Not on a branch (detached HEAD). Check out the branch to publish.' }
$origin = Invoke-Git -C $root remote get-url origin
if ($origin -notmatch 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$') { Fail "origin is not a GitHub repository: $origin" }
$owner = $Matches[1]; $repoName = $Matches[2]
$repo = "$owner/$repoName"
Ok "$repo, branch $branch"

if ($Official) {
    $settings = Read-BranchFile
    # Keep the toolkit branch: the release's toolkit may not know NOCTURNE_OFFICIAL_IMAGES yet.
    $toolsBranch = if ($settings.Contains('NOCTURNE_TOOLS_BRANCH')) { $settings['NOCTURNE_TOOLS_BRANCH'] } else { $branch }
    $toolsRepo = if ($settings.Contains('NOCTURNE_TOOLS_REPO')) { $settings['NOCTURNE_TOOLS_REPO'] } else { $repo }
    $new = [ordered]@{
        NOCTURNE_TOOLS_REPO      = $toolsRepo
        NOCTURNE_TOOLS_BRANCH    = $toolsBranch
        NOCTURNE_OFFICIAL_IMAGES = '1'
    }
    Write-BranchFile $new 'Back to the release images.'
    Ok "Wrote $BranchFile"
    Info 'The next get-nocturne run puts the VM back on the release images. Delete branch.env after that to use the default toolkit again.'
    Offer-Run (Get-GetCommand $toolsRepo $toolsBranch)
    exit 0
}

if ($branch -notlike 'feature/*') {
    Warn "The workflow builds feature/... branches on push; '$branch' is not one."
    Info "Rename the branch (git branch -m feature/<name>), or run '$WorkflowName' by hand in the GitHub Actions tab."
}

if (-not (Test-Path (Join-Path $root '.github\workflows\branch-images.yml'))) {
    Fail 'This branch has no .github/workflows/branch-images.yml, so GitHub will not build it.' @(
        'Merge or cherry-pick the commit that adds it into this branch.')
}

# ================================================================ push
$sha = Invoke-Git -C $root rev-parse HEAD
if (-not $NoPush) {
    Step 'Pushing the branch'
    $dirty = Invoke-Git -C $root status --porcelain
    if ($dirty) {
        Warn 'You have changes that are not committed. They are NOT in the images:'
        $dirty -split "`n" | Select-Object -First 10 | ForEach-Object { Info $_ }
        $ans = Read-Host 'Continue with the last commit only? (Y/N)'
        if ($ans -notmatch '^[Yy]') { Write-Host 'Cancelled. Commit your changes, then run this again.'; exit 0 }
    }
    & git -C $root push -u origin $branch
    if ($LASTEXITCODE -ne 0) { Fail 'git push failed (output above).' }
    Ok "Pushed $($sha.Substring(0, 7))"
}

# ================================================================ wait for the build
Step "Waiting for the '$WorkflowName' workflow on $($sha.Substring(0, 7)) (about 15-25 minutes)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$seenAt = Get-Date
$last = ''
$run = $null
while ($true) {
    try {
        $runs = Invoke-GitHub "/repos/$repo/actions/runs?head_sha=$sha&per_page=20"
        $run = @($runs.workflow_runs | Where-Object { $_.name -eq $WorkflowName } | Sort-Object created_at -Descending) | Select-Object -First 1
    } catch {
        Info "GitHub did not answer ($($_.Exception.Message)); trying again"
    }

    if ($run) {
        $state = "$($run.status)$(if ($run.conclusion) { ": $($run.conclusion)" })"
        if ($state -ne $last) { Info "$state  $($run.html_url)"; $last = $state }
        if ($run.status -eq 'completed') { break }
    } elseif ((Get-Date) -gt $seenAt.AddMinutes(3)) {
        Warn 'No build has started for this commit yet.'
        Info "Forks have Actions switched off at first: open https://github.com/$repo/actions and enable workflows."
        Info "Or start '$WorkflowName' by hand there (Run workflow, branch $branch)."
        $seenAt = Get-Date
    }

    if ((Get-Date) -gt $deadline) { Fail "No finished build after $TimeoutMinutes minutes." @("Check https://github.com/$repo/actions") }
    Start-Sleep 45
}
if ($run.conclusion -ne 'success') {
    Fail "The build finished as '$($run.conclusion)'." @("Logs: $($run.html_url)", 'Fix it, commit, and run this script again.')
}
Ok 'Images built'

# ================================================================ can the VM pull them?
$imageRepo = "$owner/$repoName".ToLowerInvariant()
$tag = Get-BranchTag $branch
$api = "ghcr.io/$imageRepo/nocturne-api:$tag"
$web = "ghcr.io/$imageRepo/nocturne-web:$tag"

Step 'Checking the VM can download the images without signing in'
while ($true) {
    $private = @()
    foreach ($name in 'nocturne-api', 'nocturne-web') {
        if (-not (Test-AnonymousPull "$imageRepo/$name" $tag)) { $private += $name }
    }
    if ($private.Count -eq 0) { break }
    Warn "Not downloadable without signing in: $($private -join ', ')"
    Info 'New GitHub packages are private. Make each one public (once; later builds keep it):'
    foreach ($name in $private) {
        Info "  https://github.com/users/$owner/packages/container/package/$repoName%2F$name"
        Info '  > Package settings > Danger Zone > Change visibility > Public'
    }
    $ans = Read-Host 'Press Enter to check again, or type Q to stop'
    if ($ans -match '^[Qq]') { Fail 'The VM cannot download private images.' }
}
Ok $api
Ok $web

# ================================================================ point the toolkit at them
$settings = [ordered]@{
    NOCTURNE_TOOLS_REPO   = $repo
    NOCTURNE_TOOLS_BRANCH = $branch
    NOCTURNE_API_IMAGE    = $api
    NOCTURNE_WEB_IMAGE    = $web
}
Write-BranchFile $settings "Branch build of $branch ($($sha.Substring(0, 7)))."
Step 'Toolkit settings'
Ok "Wrote $BranchFile"
Info 'get-nocturne.ps1 now downloads this branch''s toolkit and deploys these images.'
Info 'To go back to the release:  .\deploy\azure-cloud\Publish-BranchImages.ps1 -Official'

Offer-Run (Get-GetCommand $repo $branch)
