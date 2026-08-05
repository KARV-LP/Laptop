#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $testScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ScriptPath = Join-Path $testScriptDirectory '..\scripts\diagnostic\Invoke-KarvBlendTriagePanel.ps1'
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
    'Remove-Item', 'Clear-Content', 'Set-Content', 'Add-Content',
    'Copy-Item', 'Move-Item', 'Rename-Item',
    'Stop-Process', 'Start-Process',
    'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service',
    'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
    'Restart-Computer', 'Stop-Computer',
    'Format-Volume', 'Initialize-Disk', 'Clear-Disk', 'Set-Disk',
    'Set-Partition', 'Repair-Volume', 'Optimize-Volume', 'Clear-RecycleBin',
    'Get-FileHash', 'Get-Content', 'Get-ChildItem'
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
    '(?i)System\.Net\.', '(?i)DownloadString', '(?i)DownloadFile',
    '(?i)TcpClient', '(?i)UdpClient', '(?i)Get-FileHash',
    '(?i)ReadAllBytes', '(?i)OpenRead', '(?i)StreamReader',
    '(?i)BinaryReader', '(?i)FileMode\]::Open',
    '(?i)GetTempPath', '(?i)UserTempPath', '(?i)Get-Process'
)

foreach ($pattern in $forbiddenTextPatterns) {
    if ($source -match $pattern) {
        $violations.Add('Forbidden source-enumeration, content, hash, process, or network pattern: ' + $pattern)
    }
}

$requiredPatterns = @(
    '\[ValidateSet\(''Preview''\)\]',
    '\$targetDrive\s*=\s*''C:''',
    '\$excludedDrive\s*=\s*''E:''',
    'karv-blend-autosave-local-manifest-',
    'RiskClass\s*-ne\s*''MediumRiskReview''',
    'LengthBytes\s*\};\s*Descending\s*=\s*\$true',
    'SummaryContainsFileNames\s*=\s*\$false',
    'SummaryContainsFullPaths\s*=\s*\$false',
    'SummaryContainsReviewIds\s*=\s*\$false',
    'SummaryContainsManifestPath\s*=\s*\$false',
    'HtmlContainsSensitiveLocalData\s*=\s*\$true',
    'HtmlLocalOnly\s*=\s*\$true',
    'BlendFilesEnumerated\s*=\s*\$false',
    'FileContentRead\s*=\s*\$false',
    'HashesCalculated\s*=\s*\$false',
    'ActionsAvailable\s*=\s*\$false'
)

foreach ($pattern in $requiredPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing required safety pattern: ' + $pattern)
    }
}

if ($violations.Count -gt 0) {
    throw ('Static safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

$testRoot = Join-Path $env:SystemDrive ('KARV-BlendTriagePanel-Test-' + [Guid]::NewGuid().ToString('N'))
$localAppDataRoot = Join-Path $testRoot 'localappdata'
$outputDirectory = Join-Path $localAppDataRoot 'KARV\LaptopDiagnostics'
$sourceRoot = Join-Path $testRoot 'source'
$manifestPath = Join-Path $outputDirectory 'karv-blend-autosave-local-manifest-20260805-120000.json'
$originalLocalAppData = $env:LOCALAPPDATA

try {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    $env:LOCALAPPDATA = $localAppDataRoot

    $manifest = [pscustomobject]@{
        Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
        Collector = 'BlendAutosaveReview'
        ScriptVersion = '1.0.0'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Mode = 'Preview'
        SensitiveLocalData = $true
        LocalOnly = $true
        SourceRoot = $sourceRoot
        Items = @(
            [pscustomobject]@{
                ReviewId = 'R<000003>'
                FileName = 'medium-&-largest.blend'
                FullPath = (Join-Path $sourceRoot 'medium-&-largest.blend')
                LengthBytes = 300MB
                SizeMB = 300
                AgeDays = 500
                LastWriteUtc = [DateTime]::UtcNow.AddDays(-500).ToString('o')
                RiskClass = 'MediumRiskReview'
                Protected = $true
            },
            [pscustomobject]@{
                ReviewId = 'R000002'
                FileName = 'medium-second.blend'
                FullPath = (Join-Path $sourceRoot 'medium-second.blend')
                LengthBytes = 200MB
                SizeMB = 200
                AgeDays = 700
                LastWriteUtc = [DateTime]::UtcNow.AddDays(-700).ToString('o')
                RiskClass = 'MediumRiskReview'
                Protected = $true
            },
            [pscustomobject]@{
                ReviewId = 'R000001'
                FileName = 'medium-third.blend'
                FullPath = (Join-Path $sourceRoot 'medium-third.blend')
                LengthBytes = 120MB
                SizeMB = 120
                AgeDays = 250
                LastWriteUtc = [DateTime]::UtcNow.AddDays(-250).ToString('o')
                RiskClass = 'MediumRiskReview'
                Protected = $true
            },
            [pscustomobject]@{
                ReviewId = 'R000004'
                FileName = 'high-preserve.blend'
                FullPath = (Join-Path $sourceRoot 'high-preserve.blend')
                LengthBytes = 600MB
                SizeMB = 600
                AgeDays = 400
                LastWriteUtc = [DateTime]::UtcNow.AddDays(-400).ToString('o')
                RiskClass = 'HighRiskPreserve'
                Protected = $true
            },
            [pscustomobject]@{
                ReviewId = 'R000005'
                FileName = 'lower-review.blend'
                FullPath = (Join-Path $sourceRoot 'lower-review.blend')
                LengthBytes = 2MB
                SizeMB = 2
                AgeDays = 900
                LastWriteUtc = [DateTime]::UtcNow.AddDays(-900).ToString('o')
                RiskClass = 'LowerRiskReview'
                Protected = $true
            }
        )
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -ManifestPath $manifestPath `
        -OutputDirectory $outputDirectory

    if ($result.Status -ne 'Passed' -or
        $result.MediumRiskFiles -ne 3 -or
        $result.TotalGB -ne 0.605 -or
        $result.LargestItemMB -ne 300 -or
        $result.SectionFailures -ne 0 -or
        $result.ReportsCreated -ne 2) {
        throw 'Controlled runtime returned an unexpected triage summary.'
    }

    $htmlReports = @(([System.IO.DirectoryInfo]$outputDirectory).GetFiles('karv-blend-medium-risk-triage-*.html'))
    $summaryReports = @(([System.IO.DirectoryInfo]$outputDirectory).GetFiles('karv-blend-medium-risk-triage-sanitized-summary-*.json'))
    if ($htmlReports.Count -ne 1 -or $summaryReports.Count -ne 1) {
        throw 'Controlled runtime did not create exactly one local HTML report and one sanitized summary.'
    }

    $htmlText = [System.IO.File]::ReadAllText($htmlReports[0].FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryReports[0].FullName)
    $summary = $summaryText | ConvertFrom-Json

    if ($htmlText -notmatch 'DADOS LOCAIS SENSIVEIS' -or
        $htmlText -notmatch 'medium-&amp;-largest\.blend' -or
        $htmlText -notmatch 'R&lt;000003&gt;' -or
        $htmlText -match '<script\b' -or
        $htmlText -match '<a\b' -or
        $htmlText -match '<button\b' -or
        $htmlText -match '<form\b' -or
        $htmlText -match 'javascript:') {
        throw 'Local HTML warning, escaping, or no-action contract is incorrect.'
    }

    $largestPosition = $htmlText.IndexOf('medium-&amp;-largest.blend')
    $secondPosition = $htmlText.IndexOf('medium-second.blend')
    $thirdPosition = $htmlText.IndexOf('medium-third.blend')
    if ($largestPosition -lt 0 -or
        $secondPosition -le $largestPosition -or
        $thirdPosition -le $secondPosition) {
        throw 'MediumRiskReview items are not ordered by descending size.'
    }

    if ($htmlText -match 'high-preserve\.blend' -or $htmlText -match 'lower-review\.blend') {
        throw 'The local HTML contains a risk class outside MediumRiskReview.'
    }

    if ($summary.Collector -ne 'BlendMediumRiskTriage' -or
        $summary.Mode -ne 'Preview' -or
        $summary.SourceCollector -ne 'BlendAutosaveReview' -or
        $summary.Selection.RiskClass -ne 'MediumRiskReview' -or
        $summary.Summary.Files -ne 3 -or
        $summary.Summary.LargestItemMB -ne 300 -or
        @($summary.SectionFailures).Count -ne 0) {
        throw 'Sanitized summary identity, selection, metrics, or section status is incorrect.'
    }

    if (-not $summary.Privacy.SummarySanitized -or
        -not $summary.Privacy.HtmlContainsSensitiveLocalData -or
        -not $summary.Privacy.HtmlLocalOnly -or
        -not $summary.Privacy.ExcludedDriveE -or
        $summary.Privacy.SummaryContainsFileNames -ne $false -or
        $summary.Privacy.SummaryContainsFullPaths -ne $false -or
        $summary.Privacy.SummaryContainsReviewIds -ne $false -or
        $summary.Privacy.SummaryContainsManifestPath -ne $false -or
        $summary.Privacy.BlendFilesEnumerated -ne $false -or
        $summary.Privacy.FileContentRead -ne $false -or
        $summary.Privacy.HashesCalculated -ne $false -or
        $summary.Privacy.ActionsAvailable -ne $false) {
        throw 'Privacy or no-action markers are incorrect.'
    }

    $prohibitedSummarySamples = @(
        'medium-&-largest', 'medium-second', 'medium-third',
        'high-preserve', 'lower-review', 'R000001', 'R<000003>',
        [regex]::Escape($sourceRoot), [regex]::Escape($outputDirectory),
        [regex]::Escape($manifestPath)
    )
    foreach ($sample in $prohibitedSummarySamples) {
        if ($summaryText -match $sample) {
            throw ('Sanitized summary contains prohibited local data: ' + $sample)
        }
    }

    $previewRejected = $false
    try { & $resolvedScriptPath -Mode Apply -ManifestPath $manifestPath -OutputDirectory $outputDirectory | Out-Null }
    catch { $previewRejected = $true }
    if (-not $previewRejected) { throw 'A non-Preview mode was unexpectedly accepted.' }

    $excludedDriveRejected = $false
    try { & $resolvedScriptPath -ManifestPath 'E:\KARV-Forbidden\karv-blend-autosave-local-manifest-20260805-120000.json' -OutputDirectory $outputDirectory | Out-Null }
    catch {
        if ($_.Exception.Message -match 'permanently excluded drive E:') { $excludedDriveRejected = $true }
    }
    if (-not $excludedDriveRejected) { throw 'Drive E: was not explicitly rejected.' }

    $outsideCRejected = $false
    try { & $resolvedScriptPath -ManifestPath 'D:\KARV-Outside-C\karv-blend-autosave-local-manifest-20260805-120000.json' -OutputDirectory $outputDirectory | Out-Null }
    catch {
        if ($_.Exception.Message -match 'must remain on drive C:') { $outsideCRejected = $true }
    }
    if (-not $outsideCRejected) { throw 'A manifest outside drive C: was not rejected.' }

    $outsideRootRejected = $false
    try {
        & $resolvedScriptPath `
            -ManifestPath (Join-Path $testRoot 'karv-blend-autosave-local-manifest-20260805-120000.json') `
            -OutputDirectory $outputDirectory | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'must remain inside LOCALAPPDATA') { $outsideRootRejected = $true }
    }
    if (-not $outsideRootRejected) { throw 'A manifest outside the approved diagnostics root was not rejected.' }

    $wrongNameRejected = $false
    $wrongNamePath = Join-Path $outputDirectory 'unapproved-manifest.json'
    [System.IO.File]::WriteAllText($wrongNamePath, ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)
    try { & $resolvedScriptPath -ManifestPath $wrongNamePath -OutputDirectory $outputDirectory | Out-Null }
    catch {
        if ($_.Exception.Message -match 'not an approved Fase 2E local manifest name') { $wrongNameRejected = $true }
    }
    if (-not $wrongNameRejected) { throw 'An unapproved manifest filename was not rejected.' }

    $wrongIdentityRejected = $false
    $wrongIdentityPath = Join-Path $outputDirectory 'karv-blend-autosave-local-manifest-20260805-120001.json'
    $wrongIdentityManifest = $manifest | Select-Object *
    $wrongIdentityManifest.Collector = 'UnexpectedCollector'
    [System.IO.File]::WriteAllText($wrongIdentityPath, ($wrongIdentityManifest | ConvertTo-Json -Depth 10), $utf8NoBom)
    try { & $resolvedScriptPath -ManifestPath $wrongIdentityPath -OutputDirectory $outputDirectory | Out-Null }
    catch {
        if ($_.Exception.Message -match 'identity, mode, or local-only sensitivity markers are invalid') { $wrongIdentityRejected = $true }
    }
    if (-not $wrongIdentityRejected) { throw 'A manifest with an invalid collector identity was not rejected.' }

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = $commandNames.Count
        ForbiddenFound = 0
        ManifestItems = 5
        MediumRiskItems = 3
        HtmlReports = 1
        SanitizedSummaries = 1
        SectionFailures = 0
    }
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if ([System.IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
