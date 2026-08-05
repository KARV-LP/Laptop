#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if (@($parseErrors).Count -gt 0) {
    throw ('PowerShell parse errors: ' + ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; '))
}

$commandNames = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

$forbiddenCommands = @(
    'Remove-Item',
    'Clear-Content',
    'Set-Content',
    'Move-Item',
    'Copy-Item',
    'Rename-Item',
    'Format-Volume',
    'Repair-Volume',
    'Restart-Computer',
    'Stop-Computer',
    'Stop-Process',
    'Stop-Service',
    'Set-Service'
)

$violations = New-Object System.Collections.Generic.List[string]
foreach ($commandName in $commandNames) {
    if ($forbiddenCommands -contains $commandName) {
        $violations.Add('Forbidden PowerShell command: ' + $commandName)
    }
}

$source = Get-Content -LiteralPath $resolvedPath -Raw
$forbiddenPatterns = @(
    '(?i)System\.Net\.',
    '(?i)Invoke-WebRequest',
    '(?i)Invoke-RestMethod',
    '(?i)Start-BitsTransfer',
    '(?i)Directory\]::Delete',
    '(?i)DirectoryInfo\]::Delete',
    '(?i)Remove-Item'
)

foreach ($pattern in $forbiddenPatterns) {
    if ($source -match $pattern) {
        $violations.Add('Forbidden source pattern: ' + $pattern)
    }
}

$requiredPatterns = @(
    "ValidateSet\('Preview',\s*'Apply'\)",
    "\[string\]\$Mode\s*=\s*'Preview'",
    "\$MinimumAgeDays\s*-lt\s*90",
    "'\.tmp'",
    "'\.log'",
    "'\.etl'",
    "'\.dmp'",
    "\$Mode\s*-eq\s*'Apply'",
    "ApplicationsClosed",
    "ConfirmationToken",
    "KARV-LOW-RISK-CLEANUP-AUTHORIZED",
    "System\.IO\.File\]::Delete",
    "Drive E: is permanently excluded",
    "FileNamesCollected\s*=\s*\$false",
    "FullPathsCollected\s*=\s*\$false",
    "FileContentsCollected\s*=\s*\$false",
    "NetworkCollected\s*=\s*\$false"
)

foreach ($pattern in $requiredPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing required safety pattern: ' + $pattern)
    }
}

$applyIndex = $source.IndexOf("if (`$Mode -eq 'Apply')")
$deleteIndex = $source.IndexOf('[System.IO.File]::Delete')
if ($applyIndex -lt 0 -or $deleteIndex -lt 0 -or $deleteIndex -lt $applyIndex) {
    $violations.Add('File deletion is not positioned after the Apply guard.')
}

if ($violations.Count -gt 0) {
    throw ('Maintenance safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

[pscustomobject]@{
    Status         = 'Passed'
    ParsedCommands = $commandNames.Count
    ForbiddenFound = 0
    NetworkFound   = 0
    Script         = Split-Path -Leaf $resolvedPath
}
