#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestFile {
    param([string]$Path, [int]$AgeDays)
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] 2048))
    [System.IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-$AgeDays))
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) 'Production script has parse errors.'

$commands = @(
    $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
        $true
    ) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
)

$forbiddenCommands = @(
    'Remove-Item', 'Clear-Content', 'Set-Content', 'Move-Item', 'Copy-Item',
    'Rename-Item', 'Stop-Process', 'Stop-Service', 'Set-Service',
    'Restart-Computer', 'Stop-Computer', 'Invoke-WebRequest', 'Invoke-RestMethod'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Sort-Object -Unique)
Assert-True ($forbiddenFound.Count -eq 0) ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$scriptText = [System.IO.File]::ReadAllText($resolvedScriptPath)
foreach ($pattern in @(
    "ValidateSet\('Preview', 'Apply'\)",
    'KARV-LOW-RISK-CLEANUP-APPLY-AUTHORIZED',
    'ApplicationsClosed',
    "allowedExtensions = @\('\.tmp', '\.log', '\.etl'\)",
    "reviewOnlyExtension = '\.dmp'",
    'System\.IO\.File\]::Delete',
    'DirectoriesRemoved = \$false',
    'DiagnosticDumpsPreserved = \$true',
    'BlendFilesPreserved = \$true',
    'ExcludedDriveEAccessed = \$false'
)) {
    Assert-True ([regex]::IsMatch($scriptText, $pattern)) ('Required safety pattern missing: ' + $pattern)
}
foreach ($pattern in @(
    '(?i)Directory\]::Delete',
    '(?i)DirectoryInfo\]::Delete',
    '(?i)System\.Net\.',
    '(?i)Start-Process'
)) {
    Assert-True (-not [regex]::IsMatch($scriptText, $pattern)) ('Forbidden production pattern found: ' + $pattern)
}

Assert-True (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) 'LOCALAPPDATA is unavailable.'
$localAppDataDrive = [System.IO.Path]::GetPathRoot($env:LOCALAPPDATA).TrimEnd('\').ToUpperInvariant()
Assert-True ($localAppDataDrive -eq 'C:') 'Synthetic test requires LOCALAPPDATA on drive C:.'

$forcedTempRoot = Join-Path $env:LOCALAPPDATA 'Temp'
[System.IO.Directory]::CreateDirectory($forcedTempRoot) | Out-Null
$env:TEMP = $forcedTempRoot
$env:TMP = $forcedTempRoot

$systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$diagnosticsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
Assert-True ([System.IO.Path]::GetPathRoot($systemTemp).TrimEnd('\').ToUpperInvariant() -eq 'C:') `
    'Synthetic Temp root was not forced onto drive C:.'

$testId = [Guid]::NewGuid().ToString('N')
$sampleRoot = Join-Path $systemTemp ('KARV-Authorized-Cleanup-' + $testId)
$outputDirectory = Join-Path $diagnosticsRoot ('test-authorized-cleanup-' + $testId)
[System.IO.Directory]::CreateDirectory($sampleRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

try {
    $nestedDirectory = Join-Path $sampleRoot 'nested'
    [System.IO.Directory]::CreateDirectory($nestedDirectory) | Out-Null

    $files = [ordered]@{
        OldTmp = Join-Path $sampleRoot 'private-old.tmp'
        OldLog = Join-Path $sampleRoot 'private-old.log'
        OldEtl = Join-Path $nestedDirectory 'private-old.etl'
        OldDmp = Join-Path $sampleRoot 'private-old.dmp'
        OldBlend = Join-Path $sampleRoot 'private-old.blend'
        OldGlb = Join-Path $sampleRoot 'private-old.glb'
        OldTxt = Join-Path $sampleRoot 'private-old.txt'
        RecentTmp = Join-Path $sampleRoot 'private-recent.tmp'
    }

    foreach ($key in @('OldTmp', 'OldLog', 'OldEtl', 'OldDmp', 'OldBlend', 'OldGlb', 'OldTxt')) {
        New-TestFile -Path $files[$key] -AgeDays 120
    }
    New-TestFile -Path $files.RecentTmp -AgeDays 2

    $preview = & $resolvedScriptPath -Mode Preview -UserTempPath $sampleRoot -OutputDirectory $outputDirectory
    Assert-True ($preview.Status -eq 'Passed') 'Preview did not pass.'
    Assert-True ([int64]$preview.CandidateFiles -eq 3) 'Preview candidate count is incorrect.'
    Assert-True ([int64]$preview.RemovedFiles -eq 0) 'Preview removed files.'
    Assert-True ([int64]$preview.PreservedDiagnosticDumpFiles -eq 1) 'Preview did not preserve the dump.'
    foreach ($path in $files.Values) {
        Assert-True ([System.IO.File]::Exists($path)) 'Preview changed a sample file.'
    }

    $blocked = $false
    try {
        & $resolvedScriptPath -Mode Apply -UserTempPath $sampleRoot -OutputDirectory $outputDirectory | Out-Null
    }
    catch { $blocked = $true }
    Assert-True $blocked 'Apply without guards was not blocked.'

    $wrongTokenBlocked = $false
    try {
        & $resolvedScriptPath -Mode Apply -ApplicationsClosed -ConfirmationToken 'WRONG' `
            -UserTempPath $sampleRoot -OutputDirectory $outputDirectory | Out-Null
    }
    catch { $wrongTokenBlocked = $true }
    Assert-True $wrongTokenBlocked 'Apply with an incorrect token was not blocked.'

    $apply = & $resolvedScriptPath -Mode Apply -ApplicationsClosed `
        -ConfirmationToken 'KARV-LOW-RISK-CLEANUP-APPLY-AUTHORIZED' `
        -UserTempPath $sampleRoot -OutputDirectory $outputDirectory

    Assert-True ($apply.Status -eq 'Passed') 'Authorized apply did not pass.'
    Assert-True ([int64]$apply.CandidateFiles -eq 3) 'Apply candidate count is incorrect.'
    Assert-True ([int64]$apply.RemovedFiles -eq 3) 'Apply did not remove exactly three files.'
    Assert-True ([int64]$apply.DeleteFailures -eq 0) 'Apply reported delete failures.'
    Assert-True ([int64]$apply.PreservedDiagnosticDumpFiles -eq 1) 'Apply did not preserve the dump.'

    foreach ($key in @('OldTmp', 'OldLog', 'OldEtl')) {
        Assert-True (-not [System.IO.File]::Exists($files[$key])) 'An authorized file was not removed.'
    }
    foreach ($key in @('OldDmp', 'OldBlend', 'OldGlb', 'OldTxt', 'RecentTmp')) {
        Assert-True ([System.IO.File]::Exists($files[$key])) 'A protected or recent file was removed.'
    }
    Assert-True ([System.IO.Directory]::Exists($nestedDirectory)) 'A directory was removed.'

    $reportFile = Get-ChildItem -LiteralPath $outputDirectory `
        -Filter 'karv-authorized-low-risk-cleanup-apply-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    Assert-True ($null -ne $reportFile) 'Apply report was not created.'
    $reportText = [System.IO.File]::ReadAllText($reportFile.FullName)
    $report = $reportText | ConvertFrom-Json
    foreach ($sensitiveValue in @('private-old', 'private-recent', $sampleRoot)) {
        Assert-True (-not $reportText.Contains($sensitiveValue)) ('Sensitive data leaked: ' + $sensitiveValue)
    }
    Assert-True ($report.Privacy.SummarySanitized -eq $true) 'Report is not sanitized.'
    Assert-True ($report.Scope.DiagnosticDumpsPreserved -eq $true) 'Dumps are not marked preserved.'
    Assert-True ($report.Scope.DirectoriesRemoved -eq $false) 'Directory removal was reported.'

    $outsideTempRejected = $false
    try {
        & $resolvedScriptPath -Mode Preview -UserTempPath 'C:\KARV-Outside-Temp' `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch { $outsideTempRejected = $true }
    Assert-True $outsideTempRejected 'Path outside Temp was not rejected.'

    $outsideOutputRejected = $false
    try {
        & $resolvedScriptPath -Mode Preview -UserTempPath $sampleRoot `
            -OutputDirectory 'C:\KARV-Outside-Output' | Out-Null
    }
    catch { $outsideOutputRejected = $true }
    Assert-True $outsideOutputRejected 'Output outside diagnostics root was not rejected.'

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath -Mode Preview -UserTempPath 'E:\KARV-Never-Access' `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch { $excludedDriveRejected = $true }
    Assert-True $excludedDriveRejected 'Drive E: was not rejected.'

    [pscustomobject]@{
        Status = 'Passed'
        CandidateFiles = [int64]$apply.CandidateFiles
        RemovedFiles = [int64]$apply.RemovedFiles
        PreservedDiagnosticDumpFiles = [int64]$apply.PreservedDiagnosticDumpFiles
        DeleteFailures = [int64]$apply.DeleteFailures
        ForbiddenFound = [int64]$forbiddenFound.Count
    }
}
finally {
    if ([System.IO.Directory]::Exists($sampleRoot)) {
        [System.IO.Directory]::Delete($sampleRoot, $true)
    }
    if ([System.IO.Directory]::Exists($outputDirectory)) {
        [System.IO.Directory]::Delete($outputDirectory, $true)
    }
}
