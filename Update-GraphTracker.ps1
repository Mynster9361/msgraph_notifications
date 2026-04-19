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
    
    # Check if schemes exist (DelegatedWork, Application, etc.)
    if ($entry.ContainsKey('schemes')) {
        foreach ($schemeName in $entry['schemes'].Keys) {
            $schemeData = $entry['schemes'][$schemeName]
            $uniqueId = "$permName ($schemeName)" # Unique key for tracking
            
            # Filter paths relevant to THIS scheme
            $paths = [System.Collections.Generic.List[string]]::new()
            if ($entry.ContainsKey('pathSets')) {
                foreach ($pathSet in $entry['pathSets']) {
                    if ($pathSet['schemeKeys'] -contains $schemeName) {
                        foreach ($path in $pathSet['paths'].Keys) {
                            $paths.Add($path) | Out-Null
                            $allCurrentPaths.Add($path) | Out-Null
                        }
                    }
                }
            }

            $meta = @{
                name         = $permName
                scheme       = $schemeName # e.g. Application or DelegatedWork
                displayName  = $schemeData['adminDisplayName'] ?? $schemeData['userDisplayName'] ?? ''
                description  = $schemeData['adminDescription'] ?? $schemeData['userDescription'] ?? ''
                paths        = @($paths | Sort-Object -Unique)
                requiresAdmin = $schemeData['requiresAdminConsent'] ?? $true
            }

            $currentPermissions[$uniqueId] = $meta
            $explorerLibrary.Add($meta)
        }
    }
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

foreach ($id in $currentPermissions.Keys) {
    if (-not $previousPermissions.ContainsKey($id)) {
        $item = $currentPermissions[$id]
        $newEntries += @{
            date        = $today
            name        = $item['name']
            scheme      = $item['scheme']
            description = $item['description']
            type        = "New $($item['scheme']) Scope"
        }
    }
}

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

# Set GitHub Actions output if running in CI
if ($env:GITHUB_OUTPUT) {
    if ($newEntries.Count -gt 0) {
        "has_changes=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        Write-Host "  → GitHub Actions output: has_changes=true ($($newEntries.Count) new entries)"
    } else {
        "has_changes=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        Write-Host "  → GitHub Actions output: has_changes=false"
    }
}
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 6 — GENERATE RSS FEED (PERSISTENT)
# ─────────────────────────────────────────────
Write-Step 'Updating RSS Feed'
$RssPath = Join-Path $DataDir 'rss.xml'
$BaseUrl = "https://Mynster9361.github.io/msgraph_notifications"

# 1. Load existing items if the file exists
$existingItems = @()
if (Test-Path $RssPath) {
    [xml]$xmlContent = Get-Content $RssPath
    # Extract existing <item> blocks as strings
    $existingItems = $xmlContent.rss.channel.item | ForEach-Object { $_.OuterXml }
}

# 2. Generate new items
$newRssItems = foreach ($entry in $newEntries) { 
    $SafeName = [System.Security.SecurityElement]::Escape($entry.name)
    $SafeScheme = [System.Security.SecurityElement]::Escape($entry.scheme)
    $SafeDescription = [System.Security.SecurityElement]::Escape($entry.description)
    
    $title = "[$SafeScheme] New Permission: $SafeName"
    # We add a URL Fragment #perm-Name-Scheme for deep linking
    $DeepLink = "$BaseUrl#perm-$($entry.name)-$($entry.scheme)"
    
    @"
        <item>
            <title>$title</title>
            <link>$DeepLink</link>
            <description>$SafeDescription</description>
            <pubDate>$([DateTime]::UtcNow.ToString('R'))</pubDate>
            <guid isPermaLink="false">$($entry.name)-$($entry.scheme)-$($entry.date)</guid>
        </item>
"@
}

# 3. Combine and limit to latest 50 items (to keep file size sane)
$combinedItems = ($newRssItems + $existingItems) | Select-Object -First 50

$rssTemplate = @"
<?xml version="1.0" encoding="UTF-8" ?>
<rss version="2.0">
    <channel>
        <title>MS Graph Registry Updates</title>
        <link>$BaseUrl</link>
        <description>Real-time notifications for new Microsoft Graph Permissions</description>
        <lastBuildDate>$([DateTime]::UtcNow.ToString('R'))</lastBuildDate>
        $( $combinedItems -join "`n" )
    </channel>
</rss>
"@

$rssTemplate | Set-Content $RssPath -Encoding UTF8
Write-Host "✓ RSS Feed updated (Persistent) at $RssPath"
Write-StepEnd