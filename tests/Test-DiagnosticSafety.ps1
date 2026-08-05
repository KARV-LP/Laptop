#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $testScriptFile = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($testScriptFile)) {
        throw 'Unable to determine the test script path.'
    }

    $testScriptDirectory = Split-Path -Parent $testScriptFile
    $ScriptPath = Join-Path $testScriptDirectory '..\scripts\diagnostic\Invoke-KarvReadOnlyDiagnostic.ps1'
}

$resolvedPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedPath,
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
    'Set-Item',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Copy-Item',
    'Move-Item',
    'Rename-Item',
    'Stop-Process',
    'Start-Process',
    'Stop-Service',
    'Start-Service',
    'Restart-Service',
    'Set-Service',
    'Enable-ScheduledTask',
    'Disable-ScheduledTask',
    'Register-ScheduledTask',
    'Unregister-ScheduledTask',
    'Install-Module',
    'Install-Package',
    'Uninstall-Package',
    'Update-Module',
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
    'Clear-RecycleBin'
)

$forbiddenExecutables = @(
    'winget', 'choco', 'scoop', 'curl', 'wget', 'bitsadmin', 'msiexec',
    'dism', 'sfc', 'shutdown', 'format', 'diskpart', 'reg', 'sc'
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

$source = Get-Content -LiteralPath $resolvedPath -Raw
$forbiddenTextPatterns = @(
    '(?i)System\.Net\.WebClient',
    '(?i)System\.Net\.Http',
    '(?i)DownloadString',
    '(?i)DownloadFile',
    '(?i)TcpClient',
    '(?i)UdpClient',
    '(?i)WebRequest'
)

foreach ($pattern in $forbiddenTextPatterns) {
    if ($source -match $pattern) {
        $violations.Add('Forbidden network-capable pattern: ' + $pattern)
    }
}

$requiredPrivacyPatterns = @(
    'ComputerNameCollected\s*=\s*\$false',
    'UserNameCollected\s*=\s*\$false',
    'SerialCollected\s*=\s*\$false',
    'NetworkCollected\s*=\s*\$false',
    'EventMessagesCollected\s*=\s*\$false'
)

foreach ($pattern in $requiredPrivacyPatterns) {
    if ($source -notmatch $pattern) {
        $violations.Add('Missing privacy marker pattern: ' + $pattern)
    }
}

if ($violations.Count -gt 0) {
    throw ('Safety validation failed: ' + (($violations | Sort-Object -Unique) -join '; '))
}

[pscustomobject]@{
    Status          = 'Passed'
    ParsedCommands  = $commandNames.Count
    ForbiddenFound  = 0
    NetworkFound    = 0
    Script          = Split-Path -Leaf $resolvedPath
}
