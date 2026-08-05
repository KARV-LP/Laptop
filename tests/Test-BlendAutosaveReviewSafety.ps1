#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $testScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ScriptPath = Join-Path $testScriptDirectory '..\scripts\diagnostic\Invoke-KarvBlendAutosaveReview.ps1'
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object { $_.Message + ' at line ' + $_.Extent.StartLineNumber }
    throw ('PowerShell parse validation failed: ' + ($details -join '; '))
}

$forbiddenCommands = @(
    'Remove-Item',
    'Clear-Content',
    'Set-Content',
    'Add-Content',
    'Copy-Item',
    'Move-Item',
    'Rename-Item',
    'Stop-Process',
    'Start-Process',
    'Stop-Service',
    'Start-Service',
    'Restart-Service',
    'Set-Service',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Start-BitsTransfer',
    'Restart-Computer',
    'Stop-Computer',
    'Format-Volume',
    'Initialize-Disk',
    'Clear-Disk',
    'Set-Disk',
    'Set-Partition',
    'Repair-Volume',
    'Optimize-Volume',
    'Clear-RecycleBin',
    'Get-FileHash',
    'Get-Content'
)

$forbiddenExecutables = @(
    'winget', 'choco', 'scoop', 'curl', 'wget', 'bitsadmin', 'msiexec',
    'dism', 'sfc', 'shutdown', 'format', 'diskpart', 'reg', 'sc', 'blender'
)

$commandNames = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

$violations = New-Object System.Collections.Generic.List[string]
foreach ($commandName in $commandNames) {
    if ($forbiddenCommands -contains $commandName) {
        $violations.Add('Forbidden PowerShell command: ' + $commandName)
    }
    if ($forbiddenExecutables -contains $commandName.ToLowerInvariant()) {
        $violations.Add('Forbidden executable: ' + $commandName)
    }
}

$source = [System.IO.File]::ReadAllText($resolvedScriptPath)
$forbiddenTextPatterns = @(
    '(?i)System\.Net\.',
    '(?i)DownloadString',
    '(?i)DownloadFile',
    '(?i)TcpClient',
    '(?i)UdpClient',
    '(?i)Get-FileHash',
    '(?i)ReadAllBytes',
    '(?i)ReadAllText',
    '(?i)OpenRead',
    '(?i)StreamReader',
    '(?i)BinaryReader',
    '(?i)FileMode\]::Open'
)

foreach ($pattern in $forbiddenTextPatterns) {
    if ($source -match $pattern) {
        $violations.Add('Forbidden content, hash, or network pattern: ' + $pattern)
    }
}

$requiredPatterns = @(
    '\[ValidateSet\(''Preview''\)\]',
    '\$targetDrive\s*=\s*''C:''',
    '\$excludedDrive\s*=\s*''E:''',
    'OutputDirectory must remain inside LOCALAPPDATA\\KARV\\LaptopDiagnostics',
    'SummaryContainsFileNames\s*=\s*\$false',
    'SummaryContainsFullPaths\s*=\s*\$false',
    'SummaryContainsReviewIds\s*=\s*\$false',
    'DetailedManifestContainsSensitiveLocalData\s*=\s*\$true',
    'DetailedManifestLocalOnly\s*=\s*\$true',
    'FileContentRead\s*=\s*\$false',
    'HashesCalculated\s*=\s*\$false',
    'SensitiveLocalData\s*=\s*\$true',
    'HighRiskPreserve',
    'MediumRiskReview',
    'LowerRiskReview',
    'ReadErrorProtected'
)

foreach ($pattern in $requiredPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing required safety pattern: ' + $pattern)
    }
}

if ($violations.Count -gt 0) {
    throw ('Static safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

$testRoot = Join-Path $env:SystemDrive ('KARV-BlendAutosaveReview-Test-' + [Guid]::NewGuid().ToString('N'))
$sampleRoot = Join-Path $testRoot 'source'
$localAppDataRoot = Join-Path $testRoot 'localappdata'
$outputDirectory = Join-Path $localAppDataRoot 'KARV\LaptopDiagnostics'
$originalLocalAppData = $env:LOCALAPPDATA

try {
    [System.IO.Directory]::CreateDirectory($sampleRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $env:LOCALAPPDATA = $localAppDataRoot

    function New-SyntheticBlendFile {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][int64]$Length,
            [Parameter(Mandatory = $true)][DateTime]$LastWriteUtc
        )

        $path = Join-Path $sampleRoot $Name
        $stream = [System.IO.File]::OpenWrite($path)
        try {
            $stream.SetLength($Length)
        }
        finally {
            $stream.Dispose()
        }
        [System.IO.File]::SetLastWriteTimeUtc($path, $LastWriteUtc)
    }

    New-SyntheticBlendFile -Name 'autosave-archive.blend' -Length 2MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-800))
    New-SyntheticBlendFile -Name 'recovery_big.blend' -Length 150MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-400))
    New-SyntheticBlendFile -Name 'session-medium.blend' -Length 20MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-200))
    New-SyntheticBlendFile -Name 'crash-scene.blend' -Length 5MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-120))
    New-SyntheticBlendFile -Name 'quit-very-large.blend' -Length 600MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-500))
    New-SyntheticBlendFile -Name 'ordinary-project.blend' -Length 200MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-500))
    New-SyntheticBlendFile -Name 'autosave-recent.blend' -Length 50MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-30))
    [System.IO.File]::WriteAllText((Join-Path $sampleRoot 'ignored.txt'), 'not a blend file')

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $outputDirectory `
        -UserTempPath $sampleRoot `
        -MinimumAgeDays 90

    if ($result.Status -ne 'Passed' -or
        $result.SelectedFiles -ne 5 -or
        $result.HighRiskPreserve -ne 2 -or
        $result.MediumRiskReview -ne 2 -or
        $result.LowerRiskReview -ne 1 -or
        $result.ReadErrorProtected -ne 0 -or
        $result.SectionFailures -ne 0 -or
        $result.ReportsCreated -ne 2) {
        throw 'Controlled runtime returned an unexpected summary.'
    }

    $manifestReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-blend-autosave-local-manifest-*.json' -File)
    $summaryReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-blend-autosave-sanitized-summary-*.json' -File)
    if ($manifestReports.Count -ne 1 -or $summaryReports.Count -ne 1) {
        throw 'Controlled runtime did not create exactly one local manifest and one sanitized summary.'
    }

    $manifestText = [System.IO.File]::ReadAllText($manifestReports[0].FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryReports[0].FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    if ($manifest.Collector -ne 'BlendAutosaveReview' -or
        $manifest.ScriptVersion -ne '1.0.0' -or
        $manifest.SensitiveLocalData -ne $true -or
        $manifest.LocalOnly -ne $true -or
        @($manifest.Items).Count -ne 5) {
        throw 'Local manifest identity, sensitivity marker, or item count is incorrect.'
    }

    if ($manifestText -notmatch 'autosave-archive\.blend' -or
        $manifestText -notmatch [regex]::Escape($sampleRoot)) {
        throw 'Local manifest did not retain the detailed local review data.'
    }
    if ($manifestText -match 'ordinary-project\.blend' -or
        $manifestText -match 'autosave-recent\.blend') {
        throw 'Local manifest selected a non-autosave or a recent autosave.'
    }

    if ($summary.Collector -ne 'BlendAutosaveReview' -or
        $summary.Mode -ne 'Preview' -or
        $summary.Scope.TargetDrive -ne 'C:' -or
        $summary.Scope.MinimumAgeDaysExclusive -ne 90 -or
        $summary.Summary.Files -ne 5 -or
        @($summary.SectionFailures).Count -ne 0) {
        throw 'Sanitized summary identity, scope, count, or section status is incorrect.'
    }

    if (-not $summary.Privacy.SummarySanitized -or
        -not $summary.Privacy.DetailedManifestContainsSensitiveLocalData -or
        -not $summary.Privacy.DetailedManifestLocalOnly -or
        -not $summary.Privacy.ExcludedDriveE -or
        $summary.Privacy.SummaryContainsFileNames -ne $false -or
        $summary.Privacy.SummaryContainsFullPaths -ne $false -or
        $summary.Privacy.SummaryContainsReviewIds -ne $false -or
        $summary.Privacy.FileContentRead -ne $false -or
        $summary.Privacy.HashesCalculated -ne $false) {
        throw 'Privacy markers are incorrect.'
    }

    $riskCounts = @{}
    foreach ($risk in $summary.Risks) {
        $riskCounts[$risk.Name] = [int64]$risk.Files
    }
    if ($riskCounts['HighRiskPreserve'] -ne 2 -or
        $riskCounts['MediumRiskReview'] -ne 2 -or
        $riskCounts['LowerRiskReview'] -ne 1 -or
        $riskCounts['ReadErrorProtected'] -ne 0) {
        throw 'Conservative risk classification is incorrect.'
    }

    $prohibitedSummarySamples = @(
        'autosave-archive', 'recovery_big', 'session-medium', 'crash-scene',
        'quit-very-large', 'ordinary-project', 'autosave-recent',
        [regex]::Escape($sampleRoot), [regex]::Escape($outputDirectory), 'R000001'
    )
    foreach ($sample in $prohibitedSummarySamples) {
        if ($summaryText -match $sample) {
            throw ('Sanitized summary contains prohibited local data: ' + $sample)
        }
    }

    $previewRejected = $false
    try {
        & $resolvedScriptPath -Mode Apply -OutputDirectory $outputDirectory -UserTempPath $sampleRoot | Out-Null
    }
    catch {
        $previewRejected = $true
    }
    if (-not $previewRejected) {
        throw 'A non-Preview mode was unexpectedly accepted.'
    }

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath -OutputDirectory $outputDirectory -UserTempPath 'E:\KARV-Forbidden' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'permanently excluded drive E:') {
            $excludedDriveRejected = $true
        }
    }
    if (-not $excludedDriveRejected) {
        throw 'Drive E: was not explicitly rejected.'
    }

    $outsideCRejected = $false
    try {
        & $resolvedScriptPath -OutputDirectory $outputDirectory -UserTempPath 'D:\KARV-Outside-C' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'must remain on drive C:') {
            $outsideCRejected = $true
        }
    }
    if (-not $outsideCRejected) {
        throw 'A source outside drive C: was not rejected.'
    }

    $outsideOutputRejected = $false
    try {
        & $resolvedScriptPath `
            -OutputDirectory (Join-Path $testRoot 'outside-output') `
            -UserTempPath $sampleRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'must remain inside LOCALAPPDATA') {
            $outsideOutputRejected = $true
        }
    }
    if (-not $outsideOutputRejected) {
        throw 'An output directory outside the approved diagnostics root was not rejected.'
    }

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = $commandNames.Count
        ForbiddenFound = 0
        SyntheticBlendFiles = 7
        SelectedAutosaves = 5
        HighRiskPreserve = 2
        MediumRiskReview = 2
        LowerRiskReview = 1
        SectionFailures = 0
    }
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if ([System.IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
