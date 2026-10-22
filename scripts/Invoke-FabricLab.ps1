#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Snapshot', 'SetShortcut', 'BreakTarget', 'RestoreTarget', 'Export', 'Apply')]
    [string]$Action,

    [ValidateSet('main', 'dev', 'workspace')]
    [string]$Target = 'main',

    [string]$CapacityId,

    [switch]$AllowDestructiveLabChange
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$stateDirectory = Join-Path $root '.lab'
$statePath = Join-Path $stateDirectory 'state.json'
$labDescription = 'Disposable Fabric Git troubleshooting lab; synthetic data only. Managed by Invoke-FabricLab.ps1.'
$script:tokens = @{}

if ($Action -in @('BreakTarget', 'Apply') -and -not $AllowDestructiveLabChange) {
    throw "$Action changes disposable lab data or definitions. Re-run with -AllowDestructiveLabChange."
}

function Get-LabToken([string]$Resource) {
    if (-not $script:tokens.ContainsKey($Resource)) {
        $token = & az account get-access-token --resource $Resource --query accessToken --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            throw "Could not obtain an Azure CLI token for $Resource. Run az login with your Fabric account."
        }
        $script:tokens[$Resource] = $token.Trim()
    }
    return $script:tokens[$Resource]
}

function Invoke-LabRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Resource = 'https://api.fabric.microsoft.com',
        [object]$Body,
        [switch]$AllowNotFound
    )
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $(Get-LabToken $Resource)" }
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($Resource -eq 'https://storage.azure.com/') {
        $parameters.Headers['x-ms-version'] = '2023-11-03'
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body
        $parameters.ContentType = 'application/json'
        if ($Body -is [byte[]]) {
            $parameters.ContentType = 'application/octet-stream'
        }
    }
    try {
        $response = Invoke-WebRequest @parameters
    }
    catch {
        if ($AllowNotFound -and $null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return [pscustomobject]@{ StatusCode = 404; Headers = @{}; Data = $null; Content = $null }
        }
        $details = ''
        if ($null -ne $_.ErrorDetails) { $details = $_.ErrorDetails.Message }
        throw "$Method $Uri failed: $($_.Exception.Message) $details"
    }
    $data = $null
    $content = $response.Content
    if ($content -is [byte[]]) {
        $content = [Text.Encoding]::UTF8.GetString($content)
    }
    else {
        $content = [string]$content
    }
    if ($content -and $response.Headers['Content-Type'] -match 'json') {
        $data = $content | ConvertFrom-Json
    }
    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Headers = $response.Headers
        Data = $data
        Content = $content
    }
}

function Invoke-Fabric([string]$Method, [string]$Path, [object]$Body) {
    $parameters = @{ Method = $Method; Uri = "https://api.fabric.microsoft.com/v1/$Path" }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    }
    $response = Invoke-LabRequest @parameters
    if ($response.StatusCode -ne 202) {
        return $response.Data
    }
    $operationId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$response.Headers['x-ms-operation-id'], [ref]$operationId)) {
        throw 'The Fabric 202 response did not include a valid x-ms-operation-id.'
    }
    $operationUri = "https://api.fabric.microsoft.com/v1/operations/$operationId"
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $delay = 5
        if ($response.Headers['Retry-After']) {
            $delay = [Math]::Max(1, [int][string]$response.Headers['Retry-After'])
        }
        Start-Sleep -Seconds $delay
        $response = Invoke-LabRequest -Method Get -Uri $operationUri
        if ($response.Data.status -in @('Failed', 'Cancelled')) {
            throw "Fabric operation failed: $(ConvertTo-Json $response.Data -Depth 20 -Compress)"
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "Fabric operation did not finish within the polling limit: $operationUri"
        }
    } while ($response.Data.status -ne 'Succeeded')
    return (Invoke-LabRequest -Method Get -Uri "$operationUri/result").Data
}

function Save-LabState {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $script:state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Confirm-LabWorkspace {
    $workspace = Invoke-Fabric Get "workspaces/$($script:state.workspaceId)"
    if ($workspace.displayName -ne $script:state.workspaceName -or $workspace.description -ne $labDescription) {
        throw 'The saved workspace does not match this disposable lab. No changes were made.'
    }
}

function Get-SourceUri([string]$RelativePath) {
    return "https://onelake.dfs.fabric.microsoft.com/$($script:state.workspaceId)/$($script:state.sourceLakehouseId)/$RelativePath"
}

function Initialize-Target([string]$Name) {
    foreach ($path in @('Files/git-sync-lab', "Files/git-sync-lab/$Name")) {
        $uri = Get-SourceUri $path
        $existing = Invoke-LabRequest -Method Head -Uri $uri -Resource 'https://storage.azure.com/' -AllowNotFound
        if ($existing.StatusCode -eq 404) {
            Invoke-LabRequest -Method Put -Uri "${uri}?resource=directory" -Resource 'https://storage.azure.com/' | Out-Null
        }
    }
    $fileUri = Get-SourceUri "Files/git-sync-lab/$Name/sample.csv"
    $bytes = [Text.Encoding]::UTF8.GetBytes("id,branch`n1,$Name`n")
    Invoke-LabRequest -Method Put -Uri "${fileUri}?resource=file" -Resource 'https://storage.azure.com/' | Out-Null
    Invoke-LabRequest -Method Patch -Uri "${fileUri}?action=append&position=0" -Resource 'https://storage.azure.com/' -Body $bytes | Out-Null
    Invoke-LabRequest -Method Patch -Uri "${fileUri}?action=flush&position=$($bytes.Length)" -Resource 'https://storage.azure.com/' | Out-Null
}

function Set-LabShortcut([string]$Name) {
    $body = @{
        path = 'Files'
        name = 'branch_target'
        target = @{ oneLake = @{
            workspaceId = $script:state.workspaceId
            itemId = $script:state.sourceLakehouseId
            path = "Files/git-sync-lab/$Name"
        } }
    }
    Invoke-Fabric Post "workspaces/$($script:state.workspaceId)/items/$($script:state.consumerLakehouseId)/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" $body
}

function Get-LabDefinition {
    return Invoke-Fabric Post "workspaces/$($script:state.workspaceId)/lakehouses/$($script:state.consumerLakehouseId)/getDefinition"
}

if ($Action -eq 'Setup') {
    if (Test-Path -LiteralPath $statePath) {
        $script:state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Confirm-LabWorkspace
    }
    else {
        if (-not $CapacityId) {
            $capacities = Invoke-Fabric Get 'capacities'
            $trials = @($capacities.value | Where-Object { $_.state -eq 'Active' -and $_.sku -like 'FT*' })
            if ($trials.Count -ne 1) {
                throw 'Specify -CapacityId explicitly; exactly one active Fabric trial capacity was not found.'
            }
            $CapacityId = $trials[0].id
        }
        $workspace = Invoke-Fabric Post 'workspaces' @{
            displayName = "git-sync-branch-lab-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
            description = $labDescription
            capacityId = $CapacityId
        }
        $script:state = [pscustomobject]@{
            version = 1
            workspaceId = $workspace.id
            workspaceName = $workspace.displayName
            capacityId = $CapacityId
            sourceLakehouseId = $null
            consumerLakehouseId = $null
        }
        Save-LabState
    }
    foreach ($role in @('source', 'consumer')) {
        $property = "${role}LakehouseId"
        if (-not $script:state.$property) {
            $items = Invoke-Fabric Get "workspaces/$($script:state.workspaceId)/lakehouses"
            $matches = @($items.value | Where-Object { $_.displayName -eq "lh_git_$role" })
            if ($matches.Count -gt 1) { throw "Multiple lab Lakehouses match role $role." }
            if ($matches.Count -eq 1) {
                $lakehouse = $matches[0]
            }
            else {
                $lakehouse = Invoke-Fabric Post "workspaces/$($script:state.workspaceId)/lakehouses" @{
                    displayName = "lh_git_$role"
                    description = 'Synthetic branch-switch and shortcut target lab.'
                }
            }
            $script:state.$property = $lakehouse.id
            Save-LabState
        }
    }
    foreach ($name in @('main', 'dev', 'workspace')) { Initialize-Target $name }
    Set-LabShortcut 'main' | Out-Null
    Write-Output "Ready: https://app.fabric.microsoft.com/groups/$($script:state.workspaceId)/list"
    return
}

if (-not (Test-Path -LiteralPath $statePath)) {
    throw 'No local lab state exists. Run -Action Setup first.'
}
$script:state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
Confirm-LabWorkspace

switch ($Action) {
    'SetShortcut' {
        Set-LabShortcut $Target | ConvertTo-Json -Depth 20
    }
    'BreakTarget' {
        $uri = Get-SourceUri "Files/git-sync-lab/$Target"
        Invoke-LabRequest -Method Delete -Uri "${uri}?recursive=true" -Resource 'https://storage.azure.com/' | Out-Null
        Write-Output "Removed only the synthetic $Target target. Restore it with -Action RestoreTarget -Target $Target."
    }
    'RestoreTarget' {
        Initialize-Target $Target
        Write-Output "Restored the synthetic $Target target and sample.csv."
    }
    'Snapshot' {
        $connection = Invoke-Fabric Get "workspaces/$($script:state.workspaceId)/git/connection"
        $gitStatus = $null
        if ($connection.gitConnectionState -eq 'ConnectedAndInitialized') {
            $gitStatus = Invoke-Fabric Get "workspaces/$($script:state.workspaceId)/git/status"
        }
        else {
            Write-Warning "Fabric Git state: $($connection.gitConnectionState). Git synchronization has not been verified."
        }
        $targets = foreach ($name in @('main', 'dev', 'workspace')) {
            $result = Invoke-LabRequest -Method Head -Uri (Get-SourceUri "Files/git-sync-lab/$name") -Resource 'https://storage.azure.com/' -AllowNotFound
            [pscustomobject]@{ name = $name; exists = $result.StatusCode -eq 200 }
        }
        $snapshot = [pscustomobject]@{
            capturedAtUtc = [DateTime]::UtcNow.ToString('o')
            lab = $script:state
            targets = @($targets)
            shortcuts = Invoke-Fabric Get "workspaces/$($script:state.workspaceId)/items/$($script:state.consumerLakehouseId)/shortcuts"
            gitConnection = $connection
            gitStatus = $gitStatus
            consumerDefinition = Get-LabDefinition
        }
        $directory = Join-Path $stateDirectory 'snapshots'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $path = Join-Path $directory "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).json"
        $snapshot | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $path -Encoding UTF8
        Write-Output "Saved snapshot: $path"
        $shortcutUri = "https://onelake.dfs.fabric.microsoft.com/$($script:state.workspaceId)/$($script:state.consumerLakehouseId)/Files/branch_target/sample.csv"
        (Invoke-LabRequest -Method Get -Uri $shortcutUri -Resource 'https://storage.azure.com/').Content
    }
    'Export' {
        $definition = Get-LabDefinition
        $directory = Join-Path $stateDirectory 'export'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        foreach ($part in $definition.definition.parts) {
            if ($part.path -notin @('.platform', 'lakehouse.metadata.json', 'shortcuts.metadata.json', 'alm.settings.json', 'data-access-roles.json')) {
                throw "Unexpected Lakehouse definition part: $($part.path)"
            }
            if ($part.payloadType -ne 'InlineBase64') { throw "Unsupported payload type: $($part.payloadType)" }
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload))
            [IO.File]::WriteAllText((Join-Path $directory $part.path), $text, (New-Object Text.UTF8Encoding $false))
        }
        Write-Output "Exported the service definition to $directory. Use Fabric's first commit for the Git baseline."
    }
    'Apply' {
        $definition = Get-LabDefinition
        $shortcuts = @($definition.definition.parts | Where-Object { $_.path -eq 'shortcuts.metadata.json' })
        if ($shortcuts.Count -ne 1) { throw 'Expected exactly one service-generated shortcuts.metadata.json part.' }
        $metadata = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($shortcuts[0].payload)) | ConvertFrom-Json
        $matches = @($metadata | Where-Object { $_.name -eq 'branch_target' })
        if ($matches.Count -ne 1) { throw 'Expected exactly one branch_target shortcut.' }
        $matches[0].target.oneLake.path = "Files/git-sync-lab/$Target"
        $json = ConvertTo-Json -InputObject @($metadata) -Depth 30 -Compress
        $shortcuts[0].payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        Invoke-Fabric Post "workspaces/$($script:state.workspaceId)/lakehouses/$($script:state.consumerLakehouseId)/updateDefinition" $definition | Out-Null
        Write-Output "Applied the $Target shortcut definition. This API control is not a Git branch-switch test."
    }
}
