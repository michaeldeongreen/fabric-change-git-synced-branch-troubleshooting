#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $root 'scripts\Invoke-FabricLab.ps1'
$errors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The Fabric helper has PowerShell parse errors.' }
foreach ($name in @('Invoke-LabRequest', 'Invoke-Fabric')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Get-LabToken([string]$Resource) { return 'test-placeholder-not-a-credential' }
function Start-Sleep { param([int]$Seconds) }
$script:responses = New-Object 'Collections.Generic.Queue[object]'
$script:callUris = New-Object 'Collections.Generic.List[string]'
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $Body, $ContentType, [switch]$UseBasicParsing, $ErrorAction)
    $script:callUris.Add($Uri)
    if (-not $script:responses.Count) { throw 'Unexpected mock HTTP request.' }
    return $script:responses.Dequeue()
}
function Add-TestResponse([int]$Status, [hashtable]$Headers, [object]$Content) {
    $script:responses.Enqueue([pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $Content })
}
function Assert-Fails([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $failed = $true
    }
    if (-not $failed) { throw "Expected failure containing: $Message" }
    Write-Output "Guard ($Message): PASS"
}

Add-TestResponse 200 @{ 'Content-Type' = 'application/octet-stream' } ([Text.Encoding]::UTF8.GetBytes("id,branch`n1,main`n"))
$csv = Invoke-LabRequest -Method Get -Uri 'https://onelake.dfs.fabric.microsoft.com/test' -Resource 'https://storage.azure.com/'
if ($csv.Content -ne "id,branch`n1,main`n") { throw 'CSV byte response decoding failed.' }
Write-Output 'CSV byte decoding: PASS'

$operation = '11111111-2222-3333-4444-555555555555'
Add-TestResponse 202 @{
    Location = "https://wabi.example.analysis.windows.net/v1/operations/$operation"
    'x-ms-operation-id' = $operation
    'Retry-After' = '1'
} ''
foreach ($status in @('Running', 'Succeeded')) {
    Add-TestResponse 200 @{ 'Content-Type' = 'application/json' } "{`"status`":`"$status`"}"
}
Add-TestResponse 200 @{ 'Content-Type' = 'application/json' } '{"id":"test-result"}'
$result = Invoke-Fabric Post 'workspaces/test/lakehouses' @{}
if ($result.id -ne 'test-result') { throw 'LRO result was not returned.' }
if ($script:callUris[-1] -ne "https://api.fabric.microsoft.com/v1/operations/$operation/result" -or
    ($script:callUris | Where-Object { $_ -like '*wabi*' })) {
    throw 'LRO polled a noncanonical host.'
}
Write-Output 'LRO canonical polling and result: PASS'

Add-TestResponse 202 @{ 'x-ms-operation-id' = $operation } ''
Add-TestResponse 200 @{ 'Content-Type' = 'application/json' } '{"status":"Failed","error":{"errorCode":"SyntheticWorkloadFailure"}}'
Assert-Fails { Invoke-Fabric Post 'workspaces/test/lakehouses' @{} } 'SyntheticWorkloadFailure'
Add-TestResponse 202 @{ 'x-ms-operation-id' = 'not-a-guid' } ''
Assert-Fails { Invoke-Fabric Post 'workspaces/test/lakehouses' @{} } 'valid x-ms-operation-id'
foreach ($action in @('BreakTarget', 'Apply')) {
    Assert-Fails { & $helper -Action $action } 'Re-run with -AllowDestructiveLabChange'
}
if ($script:responses.Count) { throw 'Some mock HTTP responses were not consumed.' }
Write-Output 'All Fabric request tests passed; no tokens or network requests were used.'
