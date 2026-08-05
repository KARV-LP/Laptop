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

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-Condition -Condition ($parseErrors.Count -eq 0) -Message 'Production script has PowerShell parse errors.'

$commands = @(
    $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        },
        $true
    ) | ForEach-Object { $_.GetCommandName() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$forbiddenCommands = @(
    'Get-Package',
    'Get-AppxPackage',
    'Add-AppxPackage',
    'Remove-AppxPackage',
    'Start-Process',
    'Invoke-Item',
    'Invoke-Expression',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Get-FileHash',
    'Get-AuthenticodeSignature',
    'Get-ItemProperty',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Copy-Item',
    'Move-Item',
    'Rename-Item',
    'Remove-Item',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Service'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Sort-Object -Unique)
Assert-Condition -Condition ($forbiddenFound.Count -eq 0) `
    -Message ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$scriptText = [System.IO.File]::ReadAllText($resolvedScriptPath)
foreach ($forbiddenText in @(
    'winget ',
    'choco ',
    'scoop ',
    'msiexec',
    'uninstall-package',
    'update-package',
    'SafeToUpdate',
    'SafeToUninstall',
    '<script',
    '<form',
    '<button',
    '<a '
)) {
    Assert-Condition -Condition (-not $scriptText.ToLowerInvariant().Contains($forbiddenText.ToLowerInvariant())) `
        -Message ('Forbidden production text found: ' + $forbiddenText)
}

Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable for the synthetic test.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') -Message 'Synthetic diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-protected-apps-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $applications = @(
        [pscustomobject]@{
            DisplayName = 'Blender 4.5 LTS'
            DisplayVersion = '4.5.1'
            Publisher = 'Blender Foundation'
            InstallDate = '20260801'
            InstallLocation = 'C:\Synthetic\Blender'
            DisplayIcon = 'C:\Synthetic\Blender\blender.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'BlenderSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Rhinoceros 8'
            DisplayVersion = '8.0'
            Publisher = 'Robert McNeel & Associates'
            InstallDate = '20260701'
            InstallLocation = 'C:\Synthetic\Rhino'
            DisplayIcon = 'C:\Synthetic\Rhino\rhino.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'RhinoSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Adobe Substance 3D Sampler'
            DisplayVersion = '5.0'
            Publisher = 'Adobe'
            InstallDate = '20260601'
            InstallLocation = 'C:\Synthetic\Substance'
            DisplayIcon = 'C:\Synthetic\Substance\sampler.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'SubstanceSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Canon EOS Utility'
            DisplayVersion = '3.0'
            Publisher = 'Canon Inc.'
            InstallDate = '20260501'
            InstallLocation = 'E:\Excluded\Canon'
            DisplayIcon = 'E:\Excluded\Canon\utility.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'CanonSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'GitHub Desktop'
            DisplayVersion = '3.5.0'
            Publisher = 'GitHub, Inc.'
            InstallDate = '20260401'
            InstallLocation = 'C:\Synthetic\GitHubDesktop'
            DisplayIcon = 'C:\Synthetic\GitHubDesktop\app.exe'
            Scope = 'CurrentUser'
            Architecture = 'Registry64'
            RegistryKeyName = 'GitHubDesktopSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Git'
            DisplayVersion = '2.50.0'
            Publisher = 'The Git Development Community'
            InstallDate = '20260301'
            InstallLocation = 'C:\Synthetic\Git'
            DisplayIcon = 'C:\Synthetic\Git\git.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'GitSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Cloudflare Wrangler'
            DisplayVersion = '4.0.0'
            Publisher = 'Cloudflare'
            InstallDate = '20260201'
            InstallLocation = 'C:\Synthetic\Cloudflare'
            DisplayIcon = 'C:\Synthetic\Cloudflare\wrangler.exe'
            Scope = 'CurrentUser'
            Architecture = 'Registry64'
            RegistryKeyName = 'CloudflareSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Node.js'
            DisplayVersion = '22.0.0'
            Publisher = 'Node.js Foundation'
            InstallDate = '20260101'
            InstallLocation = 'C:\Synthetic\Node'
            DisplayIcon = 'C:\Synthetic\Node\node.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'NodeSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Python 3.13'
            DisplayVersion = '3.13.0'
            Publisher = 'Python Software Foundation'
            InstallDate = '20251201'
            InstallLocation = 'C:\Synthetic\Python313'
            DisplayIcon = 'C:\Synthetic\Python313\python.exe'
            Scope = 'CurrentUser'
            Architecture = 'Registry64'
            RegistryKeyName = 'Python313Synthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Python Launcher'
            DisplayVersion = ''
            Publisher = 'Python Software Foundation'
            InstallDate = '20251201'
            InstallLocation = 'C:\Synthetic\PythonLauncher'
            DisplayIcon = 'C:\Synthetic\PythonLauncher\py.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'PythonLauncherSynthetic'
        },
        [pscustomobject]@{
            DisplayName = 'Unrelated Vendor Tool'
            DisplayVersion = '1.0'
            Publisher = 'Unrelated Vendor'
            InstallDate = '20251101'
            InstallLocation = 'C:\Synthetic\Unrelated'
            DisplayIcon = 'C:\Synthetic\Unrelated\tool.exe'
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
            RegistryKeyName = 'UnrelatedSynthetic'
        }
    )

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $testDirectory `
        -InputApplications $applications

    Assert-Condition -Condition ($result.Status -eq 'Passed') -Message 'Synthetic inventory did not pass.'
    Assert-Condition -Condition ([int64]$result.ApplicationsEnumerated -eq 11) `
        -Message 'Unexpected enumerated application count.'
    Assert-Condition -Condition ([int64]$result.ProtectedRecords -eq 10) `
        -Message 'Unexpected protected record count.'
    Assert-Condition -Condition ([int64]$result.ProtectedFamiliesExpected -eq 9) `
        -Message 'Unexpected expected-family count.'
    Assert-Condition -Condition ([int64]$result.ProtectedFamiliesFound -eq 9) `
        -Message 'Unexpected found-family count.'
    Assert-Condition -Condition ([int64]$result.ProtectedFamiliesMissing -eq 0) `
        -Message 'Unexpected missing-family count.'
    Assert-Condition -Condition ([int64]$result.FamiliesWithMultipleRecords -eq 1) `
        -Message 'Unexpected duplicate-family count.'
    Assert-Condition -Condition ([int64]$result.UnknownVersionRecords -eq 1) `
        -Message 'Unexpected unknown-version count.'
    Assert-Condition -Condition ([int64]$result.ExcludedDriveReferenceRecords -eq 1) `
        -Message 'Unexpected excluded-drive record count.'
    Assert-Condition -Condition ([int64]$result.SectionFailures -eq 0) `
        -Message 'Unexpected section failures.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) `
        -Message 'Unexpected report count.'

    $manifestFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-local-manifest-*.json' `
        -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-sanitized-summary-*.json' `
        -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $htmlFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-panel-*.html' `
        -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Detailed local manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'
    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Local HTML panel was not created.'

    $manifestText = [System.IO.File]::ReadAllText($manifestFile.FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile.FullName)
    $htmlText = [System.IO.File]::ReadAllText($htmlFile.FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    Assert-Condition -Condition ($manifest.SensitiveLocalData -eq $true) `
        -Message 'Manifest is not marked sensitive.'
    Assert-Condition -Condition ($manifest.LocalOnly -eq $true) `
        -Message 'Manifest is not marked local-only.'
    Assert-Condition -Condition ($manifestText.Contains('[REDACTED_EXCLUDED_DRIVE]')) `
        -Message 'Excluded-drive metadata was not redacted.'
    Assert-Condition -Condition (-not $manifestText.Contains('E:\Excluded')) `
        -Message 'Excluded-drive path leaked into the manifest.'
    Assert-Condition -Condition ($htmlText.Contains('Blender 4.5 LTS')) `
        -Message 'Protected application data is absent from local HTML.'
    Assert-Condition -Condition (-not $htmlText.Contains('Unrelated Vendor Tool')) `
        -Message 'Unprotected application leaked into local HTML.'
    Assert-Condition -Condition (-not $htmlText.Contains('E:\Excluded')) `
        -Message 'Excluded-drive path leaked into local HTML.'

    foreach ($interactiveToken in @('<script', '<form', '<button', '<a ', 'javascript:')) {
        Assert-Condition -Condition (-not $htmlText.ToLowerInvariant().Contains($interactiveToken)) `
            -Message ('Interactive HTML token found: ' + $interactiveToken)
    }

    foreach ($sensitiveValue in @(
        'Blender 4.5 LTS',
        '4.5.1',
        'Blender Foundation',
        'C:\Synthetic\Blender',
        'Python Launcher',
        '3.13.0',
        'Adobe Substance 3D Sampler'
    )) {
        Assert-Condition -Condition (-not $summaryText.Contains($sensitiveValue)) `
            -Message ('Sensitive value leaked into sanitized summary: ' + $sensitiveValue)
    }

    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Summary is not marked sanitized.'
    Assert-Condition -Condition ($summary.Scope.ApplicationsExecuted -eq $false) `
        -Message 'Summary incorrectly reports application execution.'
    Assert-Condition -Condition ($summary.Scope.UpdatesChecked -eq $false) `
        -Message 'Summary incorrectly reports update checks.'
    Assert-Condition -Condition ($summary.Scope.ActionsAvailable -eq $false) `
        -Message 'Summary incorrectly reports available actions.'
    Assert-Condition -Condition ([int64]$summary.Summary.ProtectedRecords -eq 10) `
        -Message 'Sanitized summary protected-record count is incorrect.'

    $applyRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Apply `
            -OutputDirectory $testDirectory `
            -InputApplications $applications | Out-Null
    }
    catch {
        $applyRejected = $true
    }
    Assert-Condition -Condition $applyRejected -Message 'Apply mode was not rejected.'

    $outsideRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -OutputDirectory ('C:\KARV-Outside-' + [Guid]::NewGuid().ToString('N')) `
            -InputApplications $applications | Out-Null
    }
    catch {
        $outsideRejected = $true
    }
    Assert-Condition -Condition $outsideRejected `
        -Message 'Output outside the approved diagnostics root was not rejected.'

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -OutputDirectory 'E:\KARV-Never-Access' `
            -InputApplications $applications | Out-Null
    }
    catch {
        $excludedDriveRejected = $true
    }
    Assert-Condition -Condition $excludedDriveRejected `
        -Message 'Output on drive E: was not rejected.'

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = [int64]$commands.Count
        ForbiddenFound = [int64]$forbiddenFound.Count
        ApplicationsEnumerated = [int64]$result.ApplicationsEnumerated
        ProtectedRecords = [int64]$result.ProtectedRecords
        ProtectedFamiliesFound = [int64]$result.ProtectedFamiliesFound
        ProtectedFamiliesMissing = [int64]$result.ProtectedFamiliesMissing
        ExcludedDriveReferenceRecords = [int64]$result.ExcludedDriveReferenceRecords
        ReportsCreated = [int64]$result.ReportsCreated
        SectionFailures = [int64]$result.SectionFailures
    }
}
finally {
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
