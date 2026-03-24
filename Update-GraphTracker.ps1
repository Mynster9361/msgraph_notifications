#Requires -Version 7.0
<#
.SYNOPSIS
    MS Graph Permissions Change Tracker & Explorer Generator
.DESCRIPTION
    Fetches Microsoft Graph permission mappings, detects changes for history, 
    and generates a full library snapshot for the Explorer view.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
$MappingsUrl = 'https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/refs/heads/master/permissions/new/permissions.json'
$DescriptionsUrl = 'https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/master/permissions/permissions-descriptions.json'
$DataDir = Join-Path $PSScriptRoot 'data'
$LastSeenPath = Join-Path $DataDir 'last-seen.json'
$ChangelogPath = Join-Path $DataDir 'changelog.json'
$CurrentStatePath = Join-Path $DataDir 'current-state.json' # NEW: For the Explorer

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
function Write-Step([string]$Message) {
    Write-Host "::group::$Message"
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}
function Write-StepEnd { Write-Host '::endgroup::' }

function Invoke-JsonDownload([string]$Url, [string]$Label) {
    Write-Step "Downloading $Label"
    try {
        $raw = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
        Write-Host "  ✓ Downloaded $Label ($([Math]::Round($raw.Length / 1KB, 1)) KB)"
        Write-StepEnd
        return $raw
    }
    catch {
        Write-Error "  ✗ Failed to download $Label from $Url`n  Error: $_"
        Write-StepEnd
        throw
    }
}

# ─────────────────────────────────────────────
# STEP 1 — PREPARE
# ─────────────────────────────────────────────
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$mappingsRaw = Invoke-JsonDownload $MappingsUrl 'Mappings'
$descriptionsRaw = Invoke-JsonDownload $DescriptionsUrl 'Descriptions'

# ─────────────────────────────────────────────
# STEP 2 — PARSE & LOOKUP
# ─────────────────────────────────────────────
Write-Step 'Parsing JSON data'
$mappingsFull = $mappingsRaw | ConvertFrom-Json -Depth 100 -AsHashtable
$mappings = $mappingsFull['permissions']
$descriptions = $descriptionsRaw | ConvertFrom-Json -Depth 100 -AsHashtable

$descLookup = @{}
$scopeLists = @()
if ($descriptions.ContainsKey('delegatedScopesList')) { $scopeLists += , $descriptions['delegatedScopesList'] }
if ($descriptions.ContainsKey('applicationScopesList')) { $scopeLists += , $descriptions['applicationScopesList'] }

foreach ($scopeList in $scopeLists) {
    foreach ($scope in $scopeList) {
        if ($scope -is [hashtable] -and $scope.ContainsKey('value')) {
            $key = $scope['value']
            $descLookup[$key] = @{
                displayName = $scope['adminConsentDisplayName'] ?? ''
                description = $scope['adminConsentDescription'] ?? ''
            }
        }
    }
}
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 3 — EXTRACT STATE & BUILD EXPLORER
# ─────────────────────────────────────────────
Write-Step 'Building Explorer Library'
$currentPermissions = @{}
$explorerLibrary = [System.Collections.Generic.List[hashtable]]::new()
$allCurrentPaths = [System.Collections.Generic.HashSet[string]]::new()

foreach ($permName in $mappings.Keys) {
    $entry = $mappings[$permName]
    $paths = [System.Collections.Generic.List[string]]::new()
    
    if ($entry -is [hashtable] -and $entry.ContainsKey('pathSets')) {
        foreach ($pathSet in $entry['pathSets']) {
            if ($pathSet.ContainsKey('paths')) {
                foreach ($path in $pathSet['paths'].Keys) {
                    $paths.Add($path) | Out-Null
                    $allCurrentPaths.Add($path) | Out-Null
                }
            }
        }
    }

    $desc = $descLookup[$permName] ?? @{ displayName = ''; description = '' }
    
    # Store for change detection
    $currentPermissions[$permName] = @{
        paths = $paths; displayName = $desc['displayName']; description = $desc['description']
    }

    # Store for Explorer View
    $explorerLibrary.Add(@{
        name = $permName
        type = "Permission"
        displayName = $desc['displayName']
        description = $desc['description']
        paths = @($paths | Sort-Object)
    })
}
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 4 — DETECT CHANGES (HISTORY)
# ─────────────────────────────────────────────
Write-Step 'Detecting Changes'
$lastSeen = if (Test-Path $LastSeenPath) { Get-Content $LastSeenPath -Raw | ConvertFrom-Json -AsHashtable } else { @{ permissions = @{} } }
$previousPermissions = $lastSeen['permissions'] ?? @{}
$today = Get-Date -Format 'yyyy-MM-dd'
$newEntries = @()

foreach ($permName in $currentPermissions.Keys) {
    if (-not $previousPermissions.ContainsKey($permName)) {
        $meta = $currentPermissions[$permName]
        $newEntries += @{
            date = $today; type = 'Permission'; name = $permName
            displayName = $meta['displayName']; description = $meta['description']
            paths = @($meta['paths'])
        }
    }
}
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 5 — SAVE ALL FILES
# ─────────────────────────────────────────────
Write-Step 'Saving Data Files'

# 1. Update Changelog (History)
$changelog = if (Test-Path $ChangelogPath) { Get-Content $ChangelogPath -Raw | ConvertFrom-Json } else { @() }
if ($newEntries.Count -gt 0) {
    $updatedChangelog = $newEntries + $changelog
    $updatedChangelog | ConvertTo-Json -Depth 10 | Set-Content $ChangelogPath -Encoding UTF8
}

# 2. Update Explorer (Current Library)
$explorerLibrary | ConvertTo-Json -Depth 10 | Set-Content $CurrentStatePath -Encoding UTF8

# 3. Update Last Seen (Internal State)
@{ 
    lastUpdated = (Get-Date -Format 'o')
    permissions = $currentPermissions
    paths = @($allCurrentPaths)
} | ConvertTo-Json -Depth 10 | Set-Content $LastSeenPath -Encoding UTF8

Write-Host "✓ Sync Complete. Library Size: $($explorerLibrary.Count)"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 6 — GENERATE RSS FEED
# ─────────────────────────────────────────────
Write-Step 'Generating RSS Feed'
$RssPath = Join-Path $DataDir 'rss.xml'
$BaseUrl = "https://YOUR_GITHUB_USERNAME.github.io/YOUR_REPO_NAME" # Change these!

$rssItems = foreach ($entry in $changelog) {
    @"
        <item>
            <title>New Permission: $($entry.name)</title>
            <link>$BaseUrl</link>
            <description>$($entry.description) (Detected on $($entry.date))</description>
            <pubDate>$([DateTime]::Parse($entry.date).ToString('R'))</pubDate>
            <guid isPermaLink="false">$($entry.name)-$($entry.date)</guid>
        </item>
"@
}

$rssTemplate = @"
<?xml version="1.0" encoding="UTF-8" ?>
<rss version="2.0">
    <channel>
        <title>MS Graph Registry Updates</title>
        <link>$BaseUrl</link>
        <description>Real-time notifications for new Microsoft Graph Permissions</description>
        <lastBuildDate>$([DateTime]::UtcNow.ToString('R'))</lastBuildDate>
        $( $rssItems -join "`n" )
    </channel>
</rss>
"@

$rssTemplate | Set-Content $RssPath -Encoding UTF8
Write-Host "✓ RSS Feed generated at $RssPath"
Write-StepEnd