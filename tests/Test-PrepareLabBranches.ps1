#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $root ".lab\branch-helper-test-$([Guid]::NewGuid().ToString('N'))"
$fixture = Join-Path $scratch 'repository'
$remote = Join-Path $scratch 'remote.git'
$gitBinary = (Get-Command git -CommandType Application).Source
$approvedOrigin = 'https://github.com/michaeldeongreen/fabric-change-git-synced-branch-troubleshooting.git'
$mockContext = @{ ReportedOrigin = $approvedOrigin; Fixture = $fixture; GitBinary = $gitBinary }

function Invoke-TestGit {
    $result = & $gitBinary @args
    if ($LASTEXITCODE -ne 0) { throw "Test fixture git failed: $($args -join ' ')" }
    return $result
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw "$Label failed: expected '$Expected', got '$Actual'." }
    Write-Output "$Label : PASS"
}

function Assert-Fails([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation | Out-Host }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $failed = $true
    }
    if (-not $failed) { throw "Expected failure containing: $Message" }
    Write-Output "Guard ($Message): PASS"
}

# Only the origin identity check is mocked; all Git operations use the local bare fixture.
$gitMock = {
    if ($args[0] -ne '-C' -or $args[1] -ne $mockContext.Fixture) {
        throw 'A test Git call attempted to leave the isolated fixture.'
    }
    if (($args[-3..-1] -join ' ') -eq 'remote get-url origin') {
        $global:LASTEXITCODE = 0
        return $mockContext.ReportedOrigin
    }
    $result = & $mockContext.GitBinary @args
    $global:LASTEXITCODE = $LASTEXITCODE
    return $result
}.GetNewClosure()
Set-Item -Path Function:git -Value $gitMock

try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    $directory = Join-Path $fixture 'fabric\lh_git_consumer.Lakehouse'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $helper = Join-Path $fixture 'scripts\Prepare-LabBranches.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Prepare-LabBranches.ps1') -Destination $helper
    $platformPath = Join-Path $directory '.platform'
    $platform = @{
        metadata = @{ type = 'Lakehouse'; displayName = 'lh_git_consumer'; description = 'Baseline' }
        config = @{ version = '2.0'; logicalId = '11111111-2222-3333-4444-555555555555' }
    }
    $platform | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $platformPath -Encoding UTF8
    $shortcuts = @(@{
        name = 'branch_target'
        path = '/Files'
        target = @{ type = 'OneLake'; oneLake = @{
            workspaceId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            itemId = '11111111-aaaa-bbbb-cccc-222222222222'
            path = 'Files/git-sync-lab/main'
        } }
    })
    ConvertTo-Json -InputObject $shortcuts -Depth 10 |
        Set-Content -LiteralPath (Join-Path $directory 'shortcuts.metadata.json') -Encoding UTF8
    Invoke-TestGit init --initial-branch=main $fixture | Out-Host
    Invoke-TestGit init --bare $remote | Out-Host
    Invoke-TestGit -C $fixture config user.name 'Fabric Lab Test'
    Invoke-TestGit -C $fixture config user.email 'fabric-lab-test@example.invalid'
    Invoke-TestGit -C $fixture add .
    Invoke-TestGit -C $fixture commit -m 'Create synthetic test fixture' -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>' | Out-Host
    Invoke-TestGit -C $fixture remote add origin $remote
    Invoke-TestGit -C $fixture branch dev
    Invoke-TestGit -C $fixture branch feature/shortcut-lab
    Invoke-TestGit -C $fixture push origin main dev feature/shortcut-lab | Out-Host

    & $helper -Scenario Identical | Out-Host
    $baseline = Invoke-TestGit -C $fixture rev-parse main
    Assert-Equal (Invoke-TestGit -C $fixture rev-parse dev) $baseline 'Identical dev'
    Assert-Equal (Invoke-TestGit -C $fixture rev-parse feature/shortcut-lab) $baseline 'Identical feature'

    & $helper -Scenario Divergent | Out-Host
    $devShortcut = Invoke-TestGit -C $fixture show 'dev:fabric/lh_git_consumer.Lakehouse/shortcuts.metadata.json' | ConvertFrom-Json
    Assert-Equal $devShortcut[0].target.oneLake.path 'Files/git-sync-lab/dev' 'Divergent target'
    Assert-Equal $devShortcut[0].target.oneLake.itemId $shortcuts[0].target.oneLake.itemId 'Preserved source item ID'
    Assert-Equal (Invoke-TestGit -C $fixture branch --show-current) 'main' 'Original branch restored'

    & $helper -Scenario Conflict | Out-Host
    $firstConflict = Invoke-TestGit -C $fixture rev-parse dev
    & $helper -Scenario Conflict | Out-Host
    if ((Invoke-TestGit -C $fixture rev-parse dev) -eq $firstConflict) { throw 'The repeated conflict did not create a new change.' }
    $devPlatform = Invoke-TestGit -C $fixture show 'dev:fabric/lh_git_consumer.Lakehouse/.platform' | ConvertFrom-Json
    Assert-Equal $devPlatform.config.logicalId $platform.config.logicalId 'Preserved logical ID'
    Assert-Equal (Invoke-TestGit -C $fixture rev-parse main) $baseline 'Main not modified'
    Assert-Fails { & $helper -Scenario Identical } 'already diverged'
    $mockContext.ReportedOrigin = 'https://github.com/unrelated/repository.git'
    Assert-Fails { & $helper } 'restricted'
    $mockContext.ReportedOrigin = $approvedOrigin

    $untracked = Join-Path $fixture 'uncommitted-test.txt'
    Set-Content -LiteralPath $untracked -Value 'Synthetic guard test.'
    Assert-Fails { & $helper } 'local changes'
    Remove-Item -LiteralPath $untracked
    $platform.config.logicalId = [Guid]::Empty.ToString()
    $platform | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $platformPath -Encoding UTF8
    Invoke-TestGit -C $fixture add -- $platformPath
    Invoke-TestGit -C $fixture commit -m 'Test pre-Git empty identity guard' -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>' | Out-Host
    Assert-Fails { & $helper } 'empty logical ID'
    Write-Output 'All branch-helper integration tests passed; no GitHub or Fabric requests were made.'
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
