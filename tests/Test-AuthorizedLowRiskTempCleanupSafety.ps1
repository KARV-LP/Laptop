#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function New-TestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$AgeDays
    )

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
Assert-Condition -Condition ($parseErrors.Count -eq 0) -Message 'Production script has parse errors.'

$commands = @(
    $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        },
        $true
    ) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
)

$forbiddenCommands = @(
    'Remove-Item',
    'Clear-Content',
    'Set-Content',
    'Move-Item',
    'Copy-Item',
    'Rename-Item',
    'Stop-Process',
    'Stop-Service',
    'Set-Service',
    'Restart-Computer',
    'Stop-Computer',
    'Invoke-WebRequest',
    'Invoke-RestMethod'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Sort-Object -Unique)
Assert-Condition -Condition ($forbiddenFound.Count -eq 0) `
    -Message ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$scriptText = [System.IO.File]::ReadAllText($resolvedScriptPath)
foreach ($requiredPattern in @(
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
    Assert-Condition -Condition ([regex]::IsMatch($scriptText, $requiredPattern)) `
        -Message ('Required safety pattern missing: ' + $requiredPattern)
}

foreach ($forbiddenPattern in @(
    '(?i)Directory\]::Delete',
    '(?i)DirectoryInfo\]::Delete',
    '(?i)System\.Net\.',
    '(?i)Start-Process',
    '(?i)\.dmp''\)\s*$'
)) {
    Assert-Condition -Condition (-not [regex]::IsMatch($scriptText, $forbiddenPattern)) `
        -Message ('Forbidden production pattern found: ' + $forbiddenPattern)
}

Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable.'

$systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$diagnosticsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
Assert-Condition -Condition ([System.IO.Path]::GetPathRoot($systemTemp).TrimEnd('\').ToUpperInvariant() -eq 'C:') `
    -Message 'Synthetic test requires the user Temp directory on C:.'
Assert-Condition -Condition ([System.IO.Path]::GetPathRoot($diagnosticsRoot).TrimEnd('\').ToUpperInvariant() -eq 'C:') `
    -Message 'Synthetic test requires LOCALAPPDATA on C:.'

$testId = [Guid]::NewGuid().ToString('N')
$sampleRoot = Join-Path $systemTemp ('KARV-Authorized-Cleanup-' + $testId)
$outputDirectory = Join-Path $diagnosticsRoot ('test-authorized-cleanup-' + $testId)
[System.IO.Directory]::CreateDirectory($sampleRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

try {
    $nestedDirectory = Join-Path $sampleRoot 'nested'
    [System.IO.Directory]::CreateDirectory($nestedDirectory) | Out-Null

    $oldTmp = Join-Path $sampleRoot 'private-old.tmp'
    $oldLog = Join-Path $sampleRoot 'private-old.log'
    $oldEtl = Join-Path $nestedDirectory 'private-old.etl'
    $oldDmp = Join-Path $sampleRoot 'private-old.dmp'
    $oldBlend = Join-Path $sampleRoot 'private-old.blend'
    $oldGlb = Join-Path $sampleRoot 'private-old.glb'
    $oldTxt = Join-Path $sampleRoot 'private-old.txt'
    $recentTmp = Join-Path $sampleRoot 'private-recent.tmp'

    foreach ($path in @($oldTmp, $oldLog, $oldEtl, $oldDmp, $oldBlend, $oldGlb, $oldTxt)) {
        New-TestFile -Path $path -AgeDays 120
    }
    New-TestFile -Path $recentTmp -AgeDays 2

    $preview = & $resolvedScriptPath `
        -Mode Preview `
        -UserTempPath $sampleRoot `
        -OutputDirectory $outputDirectory

    Assert-Condition -Condition ($preview.Status -eq 'Passed') -Message 'Preview did not pass.'
    Assert-Condition -Condition ([int64]$preview.CandidateFiles -eq 3) -Message 'Preview candidate count is incorrect.'
    Assert-Condition -Condition ([int64]$preview.RemovedFiles -eq 0) -Message 'Preview removed files.'
    Assert-Condition -Condition ([int64]$preview.PreservedDiagnosticDumpFiles -eq 1) `
        -Message 'Preview did not preserve the diagnostic dump.'

    foreach ($path in @($oldTmp, $oldLog, $oldEtl, $oldDmp, $oldBlend, $oldGlb, $oldTxt, $recentTmp)) {
        Assert-Condition -Condition ([System.IO.File]::Exists($path)) -Message 'Preview changed a sample file.'
    }

    $blocked = $false
    try {
        & $resolvedScriptPath `
            -Mode Apply `
            -UserTempPath $sampleRoot `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch {
        $blocked = $true
    }
    Assert-Condition -Condition $blocked -Message 'Apply without guards was not blocked.'

    $wrongTokenBlocked = $false
    try {
        & $resolvedScriptPath `
            -Mode Apply `
            -ApplicationsClosed `
            -ConfirmationToken 'WRONG' `
            -UserTempPath $sampleRoot `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch {
        $wrongTokenBlocked = $true
    }
    Assert-Condition -Condition $wrongTokenBlocked -Message 'Apply with an incorrect token was not blocked.'

    $apply = & $resolvedScriptPath `
        -Mode Apply `
        -ApplicationsClosed `
        -ConfirmationToken 'KARV-LOW-RISK-CLEANUP-APPLY-AUTHORIZED' `
        -UserTempPath $sampleRoot `
        -OutputDirectory $outputDirectory

    Assert-Condition -Condition ($apply.Status -eq 'Passed') -Message 'Authorized apply did not pass.'
    Assert-Condition -Condition ([int64]$apply.CandidateFiles -eq 3) -Message 'Apply candidate count is incorrect.'
    Assert-Condition -Condition ([int64]$apply.RemovedFiles -eq 3) -Message 'Apply did not remove exactly three files.'
    Assert-Condition -Condition ([int64]$apply.DeleteFailures -eq 0) -Message 'Apply reported delete failures.'
    Assert-Condition -Condition ([int64]$apply.PreservedDiagnosticDumpFiles -eq 1) `
        -Message 'Apply did not report the preserved dump.'

    foreach ($path in @($oldTmp, $oldLog, $oldEtl)) {
        Assert-Condition -Condition (-not [System.IO.File]::Exists($path)) `
            -Message 'An authorized old temporary file was not removed.'
    }
    foreach ($path in @($oldDmp, $oldBlend, $oldGlb, $oldTxt, $recentTmp)) {
        Assert-Condition -Condition ([System.IO.File]::Exists($path)) `
            -Message 'A protected or recent file was removed.'
    }
    Assert-Condition -Condition ([System.IO.Directory]::Exists($nestedDirectory)) `
        -Message 'A directory was removed.'

    $reportFile = Get-ChildItem -LiteralPath $outputDirectory `
        -Filter 'karv-authorized-low-risk-cleanup-apply-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    Assert-Condition -Condition ($null -ne $reportFile) -Message 'Apply report was not created.'

    $reportText = [System.IO.File]::ReadAllText($reportFile.FullName)
    $report = $reportText | ConvertFrom-Json
    foreach ($sensitiveValue in @(
        'private-old',
        'private-recent',
        $sampleRoot
    )) {
        Assert-Condition -Condition (-not $reportText.Contains($sensitiveValue)) `
            -Message ('Sensitive data leaked into report: ' + $sensitiveValue)
    }

    Assert-Condition -Condition ($report.Privacy.SummarySanitized -eq $true) `
        -Message 'Report is not marked sanitized.'
    Assert-Condition -Condition ($report.Scope.DiagnosticDumpsPreserved -eq $true) `
        -Message 'Report does not preserve diagnostic dumps.'
    Assert-Condition -Condition ($report.Scope.DirectoriesRemoved -eq $false) `
        -Message 'Report incorrectly indicates directory removal.'

    $outsideTempRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -UserTempPath 'C:\KARV-Outside-Temp' `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch {
        $outsideTempRejected = $true
    }
    Assert-Condition -Condition $outsideTempRejected -Message 'Path outside user Temp was not rejected.'

    $outsideOutputRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -UserTempPath $sampleRoot `
            -OutputDirectory 'C:\KARV-Outside-Output' | Out-Null
    }
    catch {
        $outsideOutputRejected = $true
    }
    Assert-Condition -Condition $outsideOutputRejected -Message 'Output outside diagnostics root was not rejected.'

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -UserTempPath 'E:\KARV-Never-Access' `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch {
        $excludedDriveRejected = $true
    }
    Assert-Condition -Condition $excludedDriveRejected -Message 'Drive E: was not rejected.'

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
