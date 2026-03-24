#Requires -Version 7.0
<#
.SYNOPSIS
    MS Graph Permissions Change Tracker
.DESCRIPTION
    Fetches Microsoft Graph permission mappings and descriptions, detects new permissions/paths,
    logs changes to changelog.json, and persists state to last-seen.json.
.NOTES
    Run via GitHub Actions on a daily schedule.
    Outputs: data/changelog.json, data/last-seen.json
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
        # Use Invoke-WebRequest (not Invoke-RestMethod) to get the raw JSON string.
        # This is required because ConvertFrom-Json -AsHashtable must receive a string,
        # and Invoke-RestMethod would auto-parse first — losing the ability to handle
        # mixed-case duplicate keys (e.g. Calls.JoinGroupCallasGuest.All vs ...AsGuest.All).
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
# STEP 1 — ENSURE DATA DIRECTORY EXISTS
# ─────────────────────────────────────────────
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Write-Host "[INFO] Created data directory: $DataDir"
}

# ─────────────────────────────────────────────
# STEP 2 — DOWNLOAD SOURCE FILES
# ─────────────────────────────────────────────
$mappingsRaw = Invoke-JsonDownload $MappingsUrl     'Mappings (permissions.json)'
$descriptionsRaw = Invoke-JsonDownload $DescriptionsUrl 'Descriptions (permissions-descriptions.json)'

# ─────────────────────────────────────────────
# STEP 3 — PARSE WITH HASHTABLES (fast lookup)
# ─────────────────────────────────────────────
Write-Step 'Parsing JSON data'

# Mappings file structure:
#   { "$schema": "...", "permissions": { "PermName": { "pathSets": [...], ... }, ... } }
# We must parse the raw string with -AsHashtable to survive mixed-case duplicate keys.
$mappingsFull = $mappingsRaw | ConvertFrom-Json -Depth 100 -AsHashtable
# Unwrap the nested "permissions" object — this is where all permission entries live
$mappings = $mappingsFull['permissions']

# Descriptions file structure:
#   { "delegatedScopesList": [...], "applicationScopesList": [...] }
# Each item has: value, adminConsentDisplayName, adminConsentDescription
$descriptions = $descriptionsRaw | ConvertFrom-Json -Depth 100 -AsHashtable

# Build a fast lookup: permission name → description metadata
# Check both delegated and application scope lists
$descLookup = @{}

$scopeLists = @()
if ($descriptions.ContainsKey('delegatedScopesList')) { $scopeLists += , $descriptions['delegatedScopesList'] }
if ($descriptions.ContainsKey('applicationScopesList')) { $scopeLists += , $descriptions['applicationScopesList'] }

foreach ($scopeList in $scopeLists) {
    foreach ($scope in $scopeList) {
        if ($scope -is [hashtable] -and $scope.ContainsKey('value')) {
            $key = $scope['value']
            if (-not $descLookup.ContainsKey($key)) {
                $descLookup[$key] = @{
                    displayName = $scope['adminConsentDisplayName'] ?? ''
                    description = $scope['adminConsentDescription'] ?? ''
                }
            }
        }
    }
}

Write-Host "  ✓ Built description lookup: $($descLookup.Count) entries"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 4 — EXTRACT CURRENT STATE
# ─────────────────────────────────────────────
Write-Step 'Extracting current permissions and paths'

# permissionName → @{ paths: []; methods: []; displayName; description }
$currentPermissions = @{}
$allCurrentPaths = [System.Collections.Generic.HashSet[string]]::new()

foreach ($permName in $mappings.Keys) {
    $entry = $mappings[$permName]
    $paths = [System.Collections.Generic.List[string]]::new()
    $methods = [System.Collections.Generic.HashSet[string]]::new()

    # pathSets is an array of hashtables; each hashtable has a `paths` property and `methods` property.
    # IMPORTANT: `paths` itself is a hashtable where the KEYS are the API path strings
    # (e.g. "/users/{id}/calendars") and the values are metadata (e.g. least-privilege info).
    # We iterate .Keys to extract the path strings and collect methods from each pathSet.
    if ($entry -is [hashtable] -and $entry.ContainsKey('pathSets')) {
        foreach ($pathSet in $entry['pathSets']) {
            if ($pathSet -is [hashtable]) {
                # Extract methods from this pathSet
                if ($pathSet.ContainsKey('methods')) {
                    foreach ($method in $pathSet['methods']) {
                        $methods.Add($method) | Out-Null
                    }
                }

                # Extract paths from this pathSet
                if ($pathSet.ContainsKey('paths')) {
                    foreach ($path in $pathSet['paths'].Keys) {
                        $paths.Add($path)           | Out-Null
                        $allCurrentPaths.Add($path)  | Out-Null
                    }
                }
            }
        }
    }

    $desc = $descLookup[$permName] ?? @{ displayName = ''; description = '' }
    $currentPermissions[$permName] = @{
        paths       = $paths
        methods     = @($methods)
        displayName = $desc['displayName']
        description = $desc['description']
    }
}

Write-Host "  ✓ Unique permissions : $($currentPermissions.Count)"
Write-Host "  ✓ Unique paths       : $($allCurrentPaths.Count)"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 5 — LOAD PREVIOUS STATE
# ─────────────────────────────────────────────
Write-Step 'Loading previous state'

$lastSeen = @{ permissions = @{}; paths = @() }

if (Test-Path $LastSeenPath) {
    try {
        $lastSeen = Get-Content $LastSeenPath -Raw | ConvertFrom-Json -AsHashtable
        Write-Host "  ✓ Loaded last-seen.json"
    }
    catch {
        Write-Warning "  ⚠ Could not parse last-seen.json, treating as first run."
    }
} else {
    Write-Host "  ℹ No previous state found — first run, seeding baseline."
}

$previousPermissions = $lastSeen['permissions'] ?? @{}

# HashSet constructor requires a typed IEnumerable — cast explicitly to [string[]]
# otherwise PowerShell passes an untyped object array and .NET can't find the overload.
$previousPaths = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]($lastSeen['paths'] ?? @())
)

Write-Host "  Previous permissions : $($previousPermissions.Count)"
Write-Host "  Previous paths       : $($previousPaths.Count)"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 6 — DETECT CHANGES
# ─────────────────────────────────────────────
Write-Step 'Detecting changes'

$today = (Get-Date -Format 'yyyy-MM-dd')
$newEntries = [System.Collections.Generic.List[hashtable]]::new()

# --- New permissions ---
foreach ($permName in $currentPermissions.Keys) {
    if (-not $previousPermissions.ContainsKey($permName)) {
        $meta = $currentPermissions[$permName]
        Write-Host "  [NEW PERMISSION] $permName"
        $newEntries.Add(@{
                date        = $today
                type        = 'Permission'
                name        = $permName
                displayName = $meta['displayName']
                description = $meta['description']
                paths       = @($meta['paths'])
                methods     = @($meta['methods'])
            })
    }
}

# --- New paths (that aren't already covered by a new permission above) ---
$newPermissionPaths = [System.Collections.Generic.HashSet[string]]::new()
foreach ($entry in $newEntries) {
    foreach ($p in $entry['paths']) { $newPermissionPaths.Add($p) | Out-Null }
}

# Pre-build a reverse index: path → list of permissions that require it.
# This avoids an O(permissions) scan for every new path detected.
$pathToPerms = @{}
$pathToMethods = @{}
foreach ($permName in $currentPermissions.Keys) {
    foreach ($p in $currentPermissions[$permName]['paths']) {
        if (-not $pathToPerms.ContainsKey($p)) { $pathToPerms[$p] = [System.Collections.Generic.List[string]]::new() }
        $pathToPerms[$p].Add($permName)

        if (-not $pathToMethods.ContainsKey($p)) { $pathToMethods[$p] = [System.Collections.Generic.HashSet[string]]::new() }
        foreach ($method in $currentPermissions[$permName]['methods']) {
            $pathToMethods[$p].Add($method) | Out-Null
        }
    }
}

foreach ($path in $allCurrentPaths) {
    if (-not $previousPaths.Contains($path) -and -not $newPermissionPaths.Contains($path)) {
        Write-Host "  [NEW PATH] $path"

        $relatedPerms = $pathToPerms[$path] ?? [System.Collections.Generic.List[string]]::new()
        $methods = $pathToMethods[$path] ?? [System.Collections.Generic.HashSet[string]]::new()
        $firstPerm = $relatedPerms | Select-Object -First 1
        $desc = if ($firstPerm) { $currentPermissions[$firstPerm]['description'] } else { '' }
        $dispName = if ($firstPerm) { $currentPermissions[$firstPerm]['displayName'] } else { '' }

        $newEntries.Add(@{
                date        = $today
                type        = 'Endpoint'
                name        = $path
                displayName = $dispName
                description = $desc
                permissions = @($relatedPerms)
                methods     = @($methods | Sort-Object)
            })
    }
}

Write-Host "  ✓ Detected $($newEntries.Count) new change(s)"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 7 — UPDATE CHANGELOG
# ─────────────────────────────────────────────
Write-Step 'Updating changelog.json'

$changelog = [System.Collections.Generic.List[hashtable]]::new()

if (Test-Path $ChangelogPath) {
    try {
        $existing = Get-Content $ChangelogPath -Raw | ConvertFrom-Json
        foreach ($item in $existing) {
            $changelog.Add(($item | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable))
        }
        Write-Host "  ✓ Loaded $($changelog.Count) existing changelog entries"
    }
    catch {
        Write-Warning "  ⚠ Could not parse changelog.json — starting fresh."
    }
}

if ($newEntries.Count -gt 0) {
    # Prepend newest entries so latest appears first
    $newEntries.Reverse()
    foreach ($entry in $newEntries) {
        $changelog.Insert(0, $entry)
    }
    Write-Host "  ✓ Added $($newEntries.Count) new entry(ies) to changelog"
} else {
    Write-Host "  ℹ No changes detected — changelog unchanged"
}

$changelog | ConvertTo-Json -Depth 10 | Set-Content $ChangelogPath -Encoding UTF8
Write-Host "  ✓ Saved changelog.json ($($changelog.Count) total entries)"
Write-StepEnd

# ─────────────────────────────────────────────
# STEP 8 — SAVE CURRENT STATE AS LAST-SEEN
# ─────────────────────────────────────────────
Write-Step 'Saving last-seen.json'

# Serialize only names + flat description meta (keep file lean)
$permissionsSnapshot = @{}
foreach ($permName in $currentPermissions.Keys) {
    $meta = $currentPermissions[$permName]
    $permissionsSnapshot[$permName] = @{
        displayName = $meta['displayName']
        description = $meta['description']
        pathCount   = $meta['paths'].Count
    }
}

$snapshot = @{
    lastUpdated = (Get-Date -Format 'o')   # ISO 8601
    permissions = $permissionsSnapshot
    paths       = @($allCurrentPaths)
}

$snapshot | ConvertTo-Json -Depth 10 | Set-Content $LastSeenPath -Encoding UTF8
Write-Host "  ✓ Saved last-seen.json"
Write-StepEnd

# ─────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────
Write-Host ''
Write-Host '════════════════════════════════════════'
Write-Host '  MS Graph Tracker — Run Complete'
Write-Host "  Date        : $today"
Write-Host "  Permissions : $($currentPermissions.Count)"
Write-Host "  Paths       : $($allCurrentPaths.Count)"
Write-Host "  New changes : $($newEntries.Count)"
Write-Host '════════════════════════════════════════'

# Signal to GitHub Actions whether a commit is needed
if ($newEntries.Count -gt 0) {
    Write-Host "::notice::$($newEntries.Count) new Graph change(s) detected and logged."
    # Set output variable so the workflow step can conditionally commit
    if ($env:GITHUB_OUTPUT) {
        "has_changes=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding UTF8
    }
} else {
    if ($env:GITHUB_OUTPUT) {
        "has_changes=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding UTF8
    }
}