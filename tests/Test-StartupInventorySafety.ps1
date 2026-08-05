#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $testScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ScriptPath = Join-Path $testScriptDirectory '..\scripts\diagnostic\Invoke-KarvStartupInventory.ps1'
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
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
    'Remove-Item', 'Clear-Content', 'Set-Content', 'Add-Content',
    'Copy-Item', 'Move-Item', 'Rename-Item',
    'Start-Process', 'Stop-Process',
    'Start-Service', 'Stop-Service', 'Restart-Service', 'Set-Service',
    'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Register-ScheduledTask',
    'Unregister-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask',
    'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
    'Restart-Computer', 'Stop-Computer', 'Get-FileHash'
)

$forbiddenExecutables = @(
    'reg', 'sc', 'schtasks', 'taskkill', 'shutdown', 'winget', 'choco',
    'scoop', 'curl', 'wget', 'bitsadmin', 'msiexec', 'dism', 'sfc'
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
    '(?i)CreateSubKey', '(?i)SetValue\s*\(', '(?i)DeleteValue', '(?i)DeleteSubKey',
    '(?i)System\.Net\.', '(?i)DownloadString', '(?i)DownloadFile',
    '(?i)Get-Service', '(?i)Get-CimInstance\s+Win32_Service',
    '(?i)Get-ScheduledTask', '(?i)TaskScheduler',
    '(?i)ReadAllBytes', '(?i)OpenRead', '(?i)FileMode\]::Open'
)
foreach ($pattern in $forbiddenTextPatterns) {
    if ($source -match $pattern) {
        $violations.Add('Forbidden mutation, network, service, task, or content pattern: ' + $pattern)
    }
}

$requiredPatterns = @(
    '\[ValidateSet\(''Preview''\)\]',
    '\$targetDrive\s*=\s*''C:''',
    '\$excludedDrive\s*=\s*''E:''',
    'OpenSubKey\(\$SubKeyPath,\s*\$false\)',
    'RegistryRunAndRunOnce\s*=\s*\$true',
    'StartupFolders\s*=\s*\$true',
    'ServicesCollected\s*=\s*\$false',
    'ScheduledTasksCollected\s*=\s*\$false',
    'SummaryContainsEntryNames\s*=\s*\$false',
    'SummaryContainsCommands\s*=\s*\$false',
    'SummaryContainsPaths\s*=\s*\$false',
    'RegistryModified\s*=\s*\$false',
    'StartupFilesModified\s*=\s*\$false',
    'ProcessesChanged\s*=\s*\$false',
    'KarvApplicationPreserve', 'SystemSecurityPreserve',
    'ThirdPartyReview', 'UnresolvedPreserve'
)
foreach ($pattern in $requiredPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing required safety pattern: ' + $pattern)
    }
}

if ($violations.Count -gt 0) {
    throw ('Static safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

$testRoot = Join-Path $env:SystemDrive ('KARV-StartupInventory-Test-' + [Guid]::NewGuid().ToString('N'))
$localAppDataRoot = Join-Path $testRoot 'localappdata'
$outputDirectory = Join-Path $localAppDataRoot 'KARV\LaptopDiagnostics'
$originalLocalAppData = $env:LOCALAPPDATA

try {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $env:LOCALAPPDATA = $localAppDataRoot

    $result = & $resolvedScriptPath -Mode Preview -OutputDirectory $outputDirectory
    if ($result.Collector -ne 'WindowsStartupInventory' -or
        $result.Mode -ne 'Preview' -or
        $result.ReportsCreated -ne 2 -or
        $result.Entries -lt 0 -or
        $result.SectionFailures -lt 0) {
        throw 'Controlled runtime returned an invalid aggregate result.'
    }

    $manifestReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-startup-local-manifest-*.json' -File)
    $summaryReports = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'karv-startup-sanitized-summary-*.json' -File)
    if ($manifestReports.Count -ne 1 -or $summaryReports.Count -ne 1) {
        throw 'Controlled runtime did not create exactly one manifest and one summary.'
    }

    $manifestText = [System.IO.File]::ReadAllText($manifestReports[0].FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryReports[0].FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    if ($manifest.Collector -ne 'WindowsStartupInventory' -or
        $manifest.Mode -ne 'Preview' -or
        $manifest.SensitiveLocalData -ne $true -or
        $manifest.LocalOnly -ne $true -or
        $manifest.Scope.ServicesCollected -ne $false -or
        $manifest.Scope.ScheduledTasksCollected -ne $false) {
        throw 'Local manifest identity, sensitivity, or scope is invalid.'
    }

    foreach ($item in @($manifest.Items)) {
        if ($item.Protected -ne $true -or
            [string]::IsNullOrWhiteSpace([string]$item.Source) -or
            [string]::IsNullOrWhiteSpace([string]$item.Classification)) {
            throw 'A manifest item is not protected or is missing classification metadata.'
        }
    }

    if ($summary.Collector -ne 'WindowsStartupInventory' -or
        $summary.Mode -ne 'Preview' -or
        $summary.Scope.ServicesCollected -ne $false -or
        $summary.Scope.ScheduledTasksCollected -ne $false -or
        $summary.Summary.Entries -ne @($manifest.Items).Count) {
        throw 'Sanitized summary identity, scope, or count is invalid.'
    }

    if (-not $summary.Privacy.SummarySanitized -or
        -not $summary.Privacy.DetailedManifestContainsSensitiveLocalData -or
        -not $summary.Privacy.DetailedManifestLocalOnly -or
        -not $summary.Privacy.ExcludedDriveE -or
        $summary.Privacy.SummaryContainsEntryNames -ne $false -or
        $summary.Privacy.SummaryContainsCommands -ne $false -or
        $summary.Privacy.SummaryContainsPaths -ne $false -or
        $summary.Privacy.RegistryModified -ne $false -or
        $summary.Privacy.StartupFilesModified -ne $false -or
        $summary.Privacy.ProcessesChanged -ne $false -or
        $summary.Privacy.NetworkCollected -ne $false) {
        throw 'Summary privacy or mutation markers are invalid.'
    }

    if ($null -ne $summary.PSObject.Properties['Items'] -or
        $null -ne $summary.PSObject.Properties['EntryName'] -or
        $null -ne $summary.PSObject.Properties['CommandOrPath'] -or
        $null -ne $summary.PSObject.Properties['Location']) {
        throw 'Sanitized summary exposes detailed startup records.'
    }

    $classTotal = 0L
    foreach ($classification in @($summary.Classifications)) {
        $classTotal += [int64]$classification.Entries
    }
    if ($classTotal -ne [int64]$summary.Summary.Entries) {
        throw 'Classification totals do not match the aggregate count.'
    }

    $sourceTotal = 0L
    foreach ($sourceMetric in @($summary.Sources)) {
        $sourceTotal += [int64]$sourceMetric.Entries
    }
    if ($sourceTotal -ne [int64]$summary.Summary.Entries) {
        throw 'Source totals do not match the aggregate count.'
    }

    $previewRejected = $false
    try { & $resolvedScriptPath -Mode Apply -OutputDirectory $outputDirectory | Out-Null }
    catch { $previewRejected = $true }
    if (-not $previewRejected) { throw 'A non-Preview mode was unexpectedly accepted.' }

    $excludedDriveRejected = $false
    try { & $resolvedScriptPath -OutputDirectory 'E:\KARV-Forbidden' | Out-Null }
    catch {
        if ($_.Exception.Message -match 'permanently excluded drive E:') { $excludedDriveRejected = $true }
    }
    if (-not $excludedDriveRejected) { throw 'Drive E: was not explicitly rejected.' }

    $outsideCRejected = $false
    try { & $resolvedScriptPath -OutputDirectory 'D:\KARV-Outside-C' | Out-Null }
    catch {
        if ($_.Exception.Message -match 'must remain on drive C:') { $outsideCRejected = $true }
    }
    if (-not $outsideCRejected) { throw 'An output outside drive C: was not rejected.' }

    $outsideRootRejected = $false
    try { & $resolvedScriptPath -OutputDirectory (Join-Path $testRoot 'outside') | Out-Null }
    catch {
        if ($_.Exception.Message -match 'must remain inside LOCALAPPDATA') { $outsideRootRejected = $true }
    }
    if (-not $outsideRootRejected) { throw 'An output outside the approved local root was not rejected.' }

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = $commandNames.Count
        ForbiddenFound = 0
        Entries = [int64]$summary.Summary.Entries
        ReportsCreated = 2
        SectionFailures = @($summary.SectionFailures).Count
    }
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if ([System.IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
