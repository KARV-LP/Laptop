#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$InputDirectory,

    [string]$OutputDirectory,

    [string]$StartupManifestPath,

    [string]$ServicesManifestPath,

    [string]$ScheduledTasksManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'PersistenceTriagePanel'
$nowUtc = [DateTime]::UtcNow

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ValidatedLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [switch]$MustExist
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw ($Purpose + ' does not have a valid drive root.')
    }

    $drive = $root.TrimEnd('\').ToUpperInvariant()
    if ($drive -eq 'E:') { throw ($Purpose + ' cannot use the permanently excluded drive E:.') }
    if ($drive -ne 'C:') { throw ($Purpose + ' must remain on drive C:.') }

    $normalizedRoot = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    $normalizedPath = $fullPath.TrimEnd('\')
    $inside = [string]::Equals(
        $normalizedRoot,
        $normalizedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $inside) {
        throw ($Purpose + ' must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.')
    }

    if ($MustExist -and -not [System.IO.File]::Exists($fullPath) -and -not [System.IO.Directory]::Exists($fullPath)) {
        throw ($Purpose + ' does not exist.')
    }

    return $fullPath
}

function Test-ExcludedDriveReference {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, '(?i)(^|[\s"''=])E:\\')
}

function Convert-ToHtmlText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-LatestManifestPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $candidate = Get-ChildItem -LiteralPath $Directory -Filter $Filter -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw ($Purpose + ' was not found in the approved local diagnostics directory.')
    }

    return $candidate.FullName
}

function Read-ValidatedManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedCollector,
        [Parameter(Mandatory = $true)][string]$ItemsProperty
    )

    $manifest = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ([string](Get-OptionalPropertyValue -Object $manifest -Name 'Collector') -ne $ExpectedCollector) {
        throw ('Unexpected collector for ' + $ExpectedCollector + '.')
    }
    if ([string](Get-OptionalPropertyValue -Object $manifest -Name 'Mode') -ne 'Preview') {
        throw ('Manifest for ' + $ExpectedCollector + ' is not Preview mode.')
    }
    if ((Get-OptionalPropertyValue -Object $manifest -Name 'SensitiveLocalData') -ne $true) {
        throw ('Manifest for ' + $ExpectedCollector + ' is not marked as sensitive local data.')
    }
    if ((Get-OptionalPropertyValue -Object $manifest -Name 'LocalOnly') -ne $true) {
        throw ('Manifest for ' + $ExpectedCollector + ' is not marked local-only.')
    }
    if ($null -eq $manifest.PSObject.Properties[$ItemsProperty]) {
        throw ('Manifest for ' + $ExpectedCollector + ' does not contain ' + $ItemsProperty + '.')
    }

    return $manifest
}

function Test-IsThirdPartyProtected {
    param([AllowNull()]$Item)

    if ($null -eq $Item) { return $false }
    $classification = [string](Get-OptionalPropertyValue -Object $Item -Name 'Classification')
    $protected = Get-OptionalPropertyValue -Object $Item -Name 'Protected'
    return $classification -eq 'ThirdPartyReview' -and $protected -eq $true
}

function Join-TaskActions {
    param([AllowNull()]$Actions)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($action in @($Actions)) {
        if ($null -eq $action) { continue }
        $type = [string](Get-OptionalPropertyValue -Object $action -Name 'Type')
        $execute = [string](Get-OptionalPropertyValue -Object $action -Name 'Execute')
        $arguments = [string](Get-OptionalPropertyValue -Object $action -Name 'Arguments')
        $workingDirectory = [string](Get-OptionalPropertyValue -Object $action -Name 'WorkingDirectory')
        $text = ($type + ' | ' + $execute + ' ' + $arguments + ' | ' + $workingDirectory).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) { $parts.Add($text) }
    }
    return ($parts.ToArray() -join ' ; ')
}

function Add-TableSection {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Properties
    )

    [void]$Builder.AppendLine('<section>')
    [void]$Builder.AppendLine('<h2>' + (Convert-ToHtmlText $Title) + ' <span class="count">' + $Rows.Count + '</span></h2>')
    if ($Rows.Count -eq 0) {
        [void]$Builder.AppendLine('<p class="empty">Nenhum item desta categoria requer revisão.</p>')
        [void]$Builder.AppendLine('</section>')
        return
    }

    [void]$Builder.AppendLine('<div class="table-wrap"><table><thead><tr>')
    foreach ($header in $Headers) {
        [void]$Builder.AppendLine('<th>' + (Convert-ToHtmlText $header) + '</th>')
    }
    [void]$Builder.AppendLine('</tr></thead><tbody>')

    foreach ($row in $Rows) {
        [void]$Builder.AppendLine('<tr>')
        foreach ($propertyName in $Properties) {
            $value = Get-OptionalPropertyValue -Object $row -Name $propertyName
            [void]$Builder.AppendLine('<td>' + (Convert-ToHtmlText $value) + '</td>')
        }
        [void]$Builder.AppendLine('</tr>')
    }

    [void]$Builder.AppendLine('</tbody></table></div></section>')
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 3D.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedRootDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
if ($allowedRootDrive -ne 'C:') { throw 'LOCALAPPDATA diagnostics root must be on drive C:.' }

[System.IO.Directory]::CreateDirectory($allowedRoot) | Out-Null
if ([string]::IsNullOrWhiteSpace($InputDirectory)) { $InputDirectory = $allowedRoot }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $allowedRoot }

$validatedInputDirectory = Get-ValidatedLocalPath `
    -Path $InputDirectory `
    -AllowedRoot $allowedRoot `
    -Purpose 'InputDirectory' `
    -MustExist

$validatedOutputDirectory = Get-ValidatedLocalPath `
    -Path $OutputDirectory `
    -AllowedRoot $allowedRoot `
    -Purpose 'OutputDirectory'

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

if ([string]::IsNullOrWhiteSpace($StartupManifestPath)) {
    $StartupManifestPath = Get-LatestManifestPath `
        -Directory $validatedInputDirectory `
        -Filter 'karv-startup-local-manifest-*.json' `
        -Purpose 'Startup manifest'
}
if ([string]::IsNullOrWhiteSpace($ServicesManifestPath)) {
    $ServicesManifestPath = Get-LatestManifestPath `
        -Directory $validatedInputDirectory `
        -Filter 'karv-persistent-services-local-manifest-*.json' `
        -Purpose 'Persistent services manifest'
}
if ([string]::IsNullOrWhiteSpace($ScheduledTasksManifestPath)) {
    $ScheduledTasksManifestPath = Get-LatestManifestPath `
        -Directory $validatedInputDirectory `
        -Filter 'karv-scheduled-task-local-manifest-*.json' `
        -Purpose 'Scheduled task manifest'
}

$validatedStartupPath = Get-ValidatedLocalPath `
    -Path $StartupManifestPath `
    -AllowedRoot $allowedRoot `
    -Purpose 'StartupManifestPath' `
    -MustExist
$validatedServicesPath = Get-ValidatedLocalPath `
    -Path $ServicesManifestPath `
    -AllowedRoot $allowedRoot `
    -Purpose 'ServicesManifestPath' `
    -MustExist
$validatedScheduledTasksPath = Get-ValidatedLocalPath `
    -Path $ScheduledTasksManifestPath `
    -AllowedRoot $allowedRoot `
    -Purpose 'ScheduledTasksManifestPath' `
    -MustExist

$startupManifest = Read-ValidatedManifest `
    -Path $validatedStartupPath `
    -ExpectedCollector 'WindowsStartupInventory' `
    -ItemsProperty 'Items'
$servicesManifest = Read-ValidatedManifest `
    -Path $validatedServicesPath `
    -ExpectedCollector 'PersistentServiceInventory' `
    -ItemsProperty 'Items'
$tasksManifest = Read-ValidatedManifest `
    -Path $validatedScheduledTasksPath `
    -ExpectedCollector 'ScheduledTaskInventory' `
    -ItemsProperty 'Tasks'

$excludedDriveReferencesSkipped = 0L
$startupRows = New-Object System.Collections.Generic.List[object]
$serviceRows = New-Object System.Collections.Generic.List[object]
$taskRows = New-Object System.Collections.Generic.List[object]

foreach ($item in @($startupManifest.Items)) {
    if (-not (Test-IsThirdPartyProtected -Item $item)) { continue }
    $entryName = [string](Get-OptionalPropertyValue -Object $item -Name 'EntryName')
    $source = [string](Get-OptionalPropertyValue -Object $item -Name 'Source')
    $scope = [string](Get-OptionalPropertyValue -Object $item -Name 'Scope')
    $commandOrPath = [string](Get-OptionalPropertyValue -Object $item -Name 'CommandOrPath')
    $combined = $entryName + ' ' + $source + ' ' + $scope + ' ' + $commandOrPath
    if (Test-ExcludedDriveReference -Text $combined) {
        $excludedDriveReferencesSkipped++
        continue
    }

    $startupRows.Add([pscustomobject]@{
        Entry = $entryName
        Source = $source
        Scope = $scope
        CommandOrPath = $commandOrPath
    })
}

foreach ($item in @($servicesManifest.Items)) {
    if (-not (Test-IsThirdPartyProtected -Item $item)) { continue }
    $name = [string](Get-OptionalPropertyValue -Object $item -Name 'Name')
    $displayName = [string](Get-OptionalPropertyValue -Object $item -Name 'DisplayName')
    $state = [string](Get-OptionalPropertyValue -Object $item -Name 'State')
    $startName = [string](Get-OptionalPropertyValue -Object $item -Name 'StartName')
    $pathName = [string](Get-OptionalPropertyValue -Object $item -Name 'PathName')
    $combined = $name + ' ' + $displayName + ' ' + $state + ' ' + $startName + ' ' + $pathName
    if (Test-ExcludedDriveReference -Text $combined) {
        $excludedDriveReferencesSkipped++
        continue
    }

    $serviceRows.Add([pscustomobject]@{
        Name = $name
        DisplayName = $displayName
        State = $state
        Account = $startName
        Path = $pathName
    })
}

foreach ($item in @($tasksManifest.Tasks)) {
    if (-not (Test-IsThirdPartyProtected -Item $item)) { continue }
    $taskName = [string](Get-OptionalPropertyValue -Object $item -Name 'TaskName')
    $taskPath = [string](Get-OptionalPropertyValue -Object $item -Name 'TaskPath')
    $state = [string](Get-OptionalPropertyValue -Object $item -Name 'State')
    $author = [string](Get-OptionalPropertyValue -Object $item -Name 'Author')
    $userId = [string](Get-OptionalPropertyValue -Object $item -Name 'UserId')
    $actions = Join-TaskActions -Actions (Get-OptionalPropertyValue -Object $item -Name 'Actions')
    $triggers = @((Get-OptionalPropertyValue -Object $item -Name 'TriggerCategories')) -join ', '
    $combined = $taskName + ' ' + $taskPath + ' ' + $state + ' ' + $author + ' ' + $userId + ' ' + $actions
    if (Test-ExcludedDriveReference -Text $combined) {
        $excludedDriveReferencesSkipped++
        continue
    }

    $taskRows.Add([pscustomobject]@{
        Task = $taskName
        Folder = $taskPath
        State = $state
        Author = $author
        Account = $userId
        Actions = $actions
        Triggers = $triggers
    })
}

$orderedStartupRows = @($startupRows.ToArray() | Sort-Object Source, Entry)
$orderedServiceRows = @($serviceRows.ToArray() | Sort-Object State, DisplayName, Name)
$orderedTaskRows = @($taskRows.ToArray() | Sort-Object State, Folder, Task)
$totalReviewItems = [int64]($orderedStartupRows.Count + $orderedServiceRows.Count + $orderedTaskRows.Count)

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<!doctype html>')
[void]$builder.AppendLine('<html lang="pt-BR"><head><meta charset="utf-8">')
[void]$builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$builder.AppendLine('<title>KARV — Revisão local de persistência</title>')
[void]$builder.AppendLine('<style>')
[void]$builder.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#17212b}main{max-width:1500px;margin:0 auto;padding:28px}header,section{background:#fff;border:1px solid #d9e0e7;border-radius:10px;padding:20px;margin-bottom:18px}h1{margin:0 0 8px;font-size:26px}h2{margin:0 0 14px;font-size:20px}.warning{background:#fff4d6;border-left:5px solid #c78a00;padding:12px;margin-top:14px}.metrics{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px}.metric{background:#edf2f7;border-radius:8px;padding:10px 14px}.count{font-size:14px;background:#263746;color:#fff;border-radius:14px;padding:3px 9px;margin-left:6px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dfe5eb;padding:9px;word-break:break-word}th{background:#edf2f7;position:sticky;top:0}.empty{color:#5b6773}.footer{font-size:12px;color:#5b6773}</style>')
[void]$builder.AppendLine('</head><body><main>')
[void]$builder.AppendLine('<header><h1>KARV — Revisão local de persistência</h1>')
[void]$builder.AppendLine('<p>Painel estático e somente leitura. Exibe exclusivamente itens classificados como ThirdPartyReview nos inventários locais já concluídos.</p>')
[void]$builder.AppendLine('<div class="warning"><strong>Dados locais sensíveis.</strong> Não compartilhe este HTML, capturas, nomes, contas, comandos ou caminhos.</div>')
[void]$builder.AppendLine('<div class="metrics">')
[void]$builder.AppendLine('<div class="metric"><strong>Total:</strong> ' + $totalReviewItems + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Inicialização:</strong> ' + $orderedStartupRows.Count + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Serviços:</strong> ' + $orderedServiceRows.Count + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Tarefas:</strong> ' + $orderedTaskRows.Count + '</div>')
[void]$builder.AppendLine('</div></header>')

Add-TableSection `
    -Builder $builder `
    -Title 'Inicialização do Windows' `
    -Headers @('Entrada', 'Origem', 'Escopo', 'Comando ou caminho') `
    -Rows $orderedStartupRows `
    -Properties @('Entry', 'Source', 'Scope', 'CommandOrPath')

Add-TableSection `
    -Builder $builder `
    -Title 'Serviços persistentes' `
    -Headers @('Nome interno', 'Nome exibido', 'Estado', 'Conta', 'Caminho') `
    -Rows $orderedServiceRows `
    -Properties @('Name', 'DisplayName', 'State', 'Account', 'Path')

Add-TableSection `
    -Builder $builder `
    -Title 'Tarefas agendadas' `
    -Headers @('Tarefa', 'Pasta', 'Estado', 'Autor', 'Conta', 'Ações', 'Gatilhos') `
    -Rows $orderedTaskRows `
    -Properties @('Task', 'Folder', 'State', 'Author', 'Account', 'Actions', 'Triggers')

[void]$builder.AppendLine('<section class="footer">Nenhuma ação está disponível neste painel. Nenhum item foi alterado, executado, iniciado, parado, habilitado ou desabilitado.</section>')
[void]$builder.AppendLine('</main></body></html>')

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$htmlPath = Join-Path $validatedOutputDirectory ('karv-persistence-triage-panel-' + $timestamp + '.html')
$summaryPath = Join-Path $validatedOutputDirectory ('karv-persistence-triage-sanitized-summary-' + $timestamp + '.json')

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsNames = $false
        SummaryContainsAccounts = $false
        SummaryContainsCommands = $false
        SummaryContainsPaths = $false
        SummaryContainsManifestPaths = $false
        HtmlContainsSensitiveLocalData = $true
        HtmlLocalOnly = $true
        ExcludedDriveE = $true
        ExcludedDriveReferencesSkipped = [int64]$excludedDriveReferencesSkipped
    }
    Scope = [pscustomobject]@{
        SourceManifests = 3
        SourceManifestsAutoDetected = [bool](
            -not $PSBoundParameters.ContainsKey('StartupManifestPath') -and
            -not $PSBoundParameters.ContainsKey('ServicesManifestPath') -and
            -not $PSBoundParameters.ContainsKey('ScheduledTasksManifestPath')
        )
        ThirdPartyReviewOnly = $true
        ProtectedOnly = $true
        WindowsReenumerated = $false
        RegistryReadAgain = $false
        StartupFoldersReadAgain = $false
        ServicesReadAgain = $false
        ScheduledTasksReadAgain = $false
        ReferencedFilesOpened = $false
        HashesCalculated = $false
        NetworkCollected = $false
        ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        ReviewItems = $totalReviewItems
        StartupItems = [int64]$orderedStartupRows.Count
        ServiceItems = [int64]$orderedServiceRows.Count
        ScheduledTaskItems = [int64]$orderedTaskRows.Count
    }
    SectionFailures = @()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($htmlPath, $builder.ToString(), $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), $utf8NoBom)

[pscustomobject]@{
    Status = 'Passed'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    ReviewItems = $totalReviewItems
    StartupItems = [int64]$orderedStartupRows.Count
    ServiceItems = [int64]$orderedServiceRows.Count
    ScheduledTaskItems = [int64]$orderedTaskRows.Count
    ExcludedDriveReferencesSkipped = [int64]$excludedDriveReferencesSkipped
    SectionFailures = 0
    ReportsCreated = 2
}
