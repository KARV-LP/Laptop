#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $testScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ScriptPath = Join-Path $testScriptDirectory '..\scripts\diagnostic\Invoke-KarvBlendUserTempClassifier.ps1'
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
        $violations.Add('Forbidden content or network pattern: ' + $pattern)
    }
}

$requiredPatterns = @(
    '\[ValidateSet\(''Preview''\)\]',
    '\$targetDrive\s*=\s*''C:''',
    '\$excludedDrive\s*=\s*''E:''',
    'FileNamesCollected\s*=\s*\$false',
    'FullPathsCollected\s*=\s*\$false',
    'FileContentRead\s*=\s*\$false',
    'HashesCalculated\s*=\s*\$false',
    'ProcessDetailsCollected\s*=\s*\$false',
    'ConfirmedDuplicates\s*=\s*0L',
    'MetadataSignalsOnly'
)

foreach ($pattern in $requiredPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing required safety pattern: ' + $pattern)
    }
}

if ($violations.Count -gt 0) {
    throw ('Static safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

$testRoot = Join-Path $env:SystemDrive ('KARV-BlendClassifier-Test-' + [Guid]::NewGuid().ToString('N'))
$sampleRoot = Join-Path $testRoot 'source'
$outputDirectory = Join-Path $testRoot 'output'

try {
    [System.IO.Directory]::CreateDirectory($sampleRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

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

    $duplicateTime = [DateTime]::UtcNow.AddDays(-40)
    New-SyntheticBlendFile -Name 'active-scene.blend' -Length 1MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-1))
    New-SyntheticBlendFile -Name 'quit.blend' -Length 2MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-20))
    New-SyntheticBlendFile -Name 'chair-copy.blend' -Length 3MB -LastWriteUtc $duplicateTime
    New-SyntheticBlendFile -Name 'table-copy.blend' -Length 3MB -LastWriteUtc $duplicateTime
    New-SyntheticBlendFile -Name 'large-project.blend' -Length 105MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-60))
    New-SyntheticBlendFile -Name 'historic-scene.blend' -Length 4MB -LastWriteUtc ([DateTime]::UtcNow.AddDays(-120))
    [System.IO.File]::WriteAllText((Join-Path $sampleRoot 'ignored.txt'), 'not a blend file')

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $outputDirectory `
        -UserTempPath $sampleRoot

    if ($result.Status -ne 'Passed' -or $result.BlendFiles -ne 6 -or $result.SectionFailures -ne 0) {
        throw 'Controlled runtime returned an unexpected summary.'
    }

    $jsonReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-blend-user-temp-preview-*.json' -File)
    $markdownReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-blend-user-temp-summary-*.md' -File)
    if ($jsonReports.Count -ne 1 -or $markdownReports.Count -ne 1) {
        throw 'Controlled runtime did not create exactly one JSON and one Markdown report.'
    }

    $jsonText = [System.IO.File]::ReadAllText($jsonReports[0].FullName)
    $report = $jsonText | ConvertFrom-Json

    if ($report.Collector -ne 'BlendUserTempClassifier' -or $report.ScriptVersion -ne '1.0.0') {
        throw 'Unexpected collector identity or version.'
    }
    if ($report.Mode -ne 'Preview' -or $report.Scope.TargetDrive -ne 'C:' -or $report.Scope.Extension -ne '.blend') {
        throw 'Scope or Preview enforcement is incorrect.'
    }
    if (-not $report.Privacy.Sanitized -or -not $report.Privacy.ExcludedDriveE) {
        throw 'Privacy or E drive exclusion markers are missing.'
    }
    if ($report.Privacy.FileNamesCollected -ne $false -or
        $report.Privacy.FullPathsCollected -ne $false -or
        $report.Privacy.FileContentRead -ne $false -or
        $report.Privacy.HashesCalculated -ne $false) {
        throw 'A prohibited collection marker is enabled.'
    }
    if (@($report.SectionFailures).Count -ne 0 -or $report.Summary.Files -ne 6) {
        throw 'Unexpected section failure or file count.'
    }

    $categoryCounts = @{}
    foreach ($category in $report.Categories) {
        $categoryCounts[$category.Name] = [int64]$category.Files
    }

    if ($categoryCounts['PossiblyActiveOrRecentlyModified'] -ne 1 -or
        $categoryCounts['PossibleAutosaveOrRecovery'] -ne 1 -or
        $categoryCounts['PossibleBackupOrVersionCopy'] -ne 2 -or
        $categoryCounts['LargeProjectLikeFile'] -ne 1 -or
        $categoryCounts['UnclassifiedProtected'] -ne 1 -or
        $categoryCounts['ReadErrorProtected'] -ne 0) {
        throw 'Conservative category classification is incorrect.'
    }

    if ($report.CandidateDuplicateGroups.Method -ne 'MetadataSignalsOnly' -or
        $report.CandidateDuplicateGroups.HashesCalculated -ne $false -or
        $report.CandidateDuplicateGroups.ConfirmedDuplicates -ne 0 -or
        $report.CandidateDuplicateGroups.CandidateGroups -ne 1 -or
        $report.CandidateDuplicateGroups.FilesInCandidateGroups -ne 2) {
        throw 'Candidate duplicate grouping is incorrect or overclaims confirmation.'
    }

    $prohibitedSamples = @(
        'active-scene', 'quit.blend', 'chair-copy', 'table-copy',
        'large-project', 'historic-scene', [regex]::Escape($sampleRoot), [regex]::Escape($outputDirectory)
    )
    foreach ($sample in $prohibitedSamples) {
        if ($jsonText -match $sample) {
            throw ('Sanitized JSON contains prohibited sample data: ' + $sample)
        }
    }

    $markdownText = [System.IO.File]::ReadAllText($markdownReports[0].FullName)
    foreach ($sample in $prohibitedSamples) {
        if ($markdownText -match $sample) {
            throw ('Sanitized Markdown contains prohibited sample data: ' + $sample)
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

    [pscustomobject]@{
        Status              = 'Passed'
        ParsedCommands      = $commandNames.Count
        ForbiddenFound      = 0
        SyntheticBlendFiles = 6
        CandidateGroups     = 1
        SectionFailures     = 0
    }
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
