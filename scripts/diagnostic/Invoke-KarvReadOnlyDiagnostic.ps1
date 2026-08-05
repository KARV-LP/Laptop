#requires -Version 5.1
<#+
.SYNOPSIS
    Generates a sanitized technical baseline for the KARV laptop.
.DESCRIPTION
    Runs read-only Windows queries. The only local effect is writing report
    files to the output directory. It does not install, remove, update, repair,
    or transmit data.
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'),
    [ValidateRange(1, 30)]
    [int]$EventLookbackDays = 7,
    [ValidateRange(5, 50)]
    [int]$TopProcessCount = 15,
    [switch]$SkipCacheScan
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:SectionFailures = New-Object System.Collections.Generic.List[object]

function Add-SectionFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    $script:SectionFailures.Add([pscustomobject]@{
        Section   = $Section
        ErrorType = $Exception.GetType().Name
    })
}

function Convert-BytesToGB {
    param([AllowNull()][object]$Bytes)

    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Protect-Text {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    $replacements = @()

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $replacements += [pscustomobject]@{ Pattern = [regex]::Escape($env:USERPROFILE); Replacement = '<USERPROFILE>' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $replacements += [pscustomobject]@{ Pattern = [regex]::Escape($env:USERNAME); Replacement = '<USER>' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $replacements += [pscustomobject]@{ Pattern = [regex]::Escape($env:COMPUTERNAME); Replacement = '<COMPUTER>' }
    }

    foreach ($item in $replacements) {
        $text = [regex]::Replace($text, $item.Pattern, $item.Replacement, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    $text = [regex]::Replace($text, '(?i)C:\\Users\\[^\\\s"'']+', 'C:\Users\<USER>')
    $text = [regex]::Replace($text, '(?i)\b[A-F0-9]{2}(?:[:-][A-F0-9]{2}){5}\b', '<MAC>')
    $text = [regex]::Replace($text, '(?i)\b[\w.%+-]+@[\w.-]+\.[A-Z]{2,}\b', '<EMAIL>')
    $text = [regex]::Replace($text, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)', '<IP>')

    return $text
}

function Get-SafeOutputDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $cursor = New-Object System.IO.DirectoryInfo($fullPath)

    while ($null -ne $cursor) {
        if (Test-Path -LiteralPath (Join-Path $cursor.FullName '.git')) {
            throw 'The output directory cannot be inside a Git repository.'
        }
        $cursor = $cursor.Parent
    }

    if (-not (Test-Path -LiteralPath $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }

    return $fullPath
}

function Get-DirectorySizeSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Label  = $Label
            Exists = $false
            SizeGB = 0
        }
    }

    $measurement = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum

    return [pscustomobject]@{
        Label  = $Label
        Exists = $true
        SizeGB = Convert-BytesToGB $measurement.Sum
    }
}

function Get-InstalledApplications {
    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = foreach ($registryPath in $registryPaths) {
        Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                $displayName = Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName'

                if (-not [string]::IsNullOrWhiteSpace([string]$displayName)) {
                    [pscustomobject]@{
                        Name        = Protect-Text $displayName
                        Version     = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayVersion')
                        Publisher   = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'Publisher')
                        InstallDate = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'InstallDate')
                    }
                }
            }
    }

    return @($items | Sort-Object Name, Version, Publisher -Unique)
}

function Get-SelectedDriverInventory {
    $selectedClasses = @('DISPLAY', 'NET', 'SCSIADAPTER', 'HDC', 'SYSTEM', 'MEDIA')

    return @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceClass -and ($selectedClasses -contains ([string]$_.DeviceClass).ToUpperInvariant()) } |
        ForEach-Object {
            [pscustomobject]@{
                DeviceName     = Protect-Text $_.DeviceName
                DeviceClass    = Protect-Text $_.DeviceClass
                Manufacturer   = Protect-Text $_.Manufacturer
                Provider       = Protect-Text $_.DriverProviderName
                DriverVersion  = Protect-Text $_.DriverVersion
                DriverDate     = $_.DriverDate
            }
        } |
        Sort-Object DeviceClass, DeviceName)
}

function Get-EventSummary {
    param([Parameter(Mandatory = $true)][datetime]$StartTime)

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = @('System', 'Application')
        Level     = @(1, 2)
        StartTime = $StartTime
    } -MaxEvents 5000 -ErrorAction Stop

    return @($events |
        Group-Object LogName, ProviderName, Id, LevelDisplayName |
        Sort-Object Count -Descending |
        Select-Object -First 50 |
        ForEach-Object {
            $sample = $_.Group | Select-Object -First 1
            [pscustomobject]@{
                LogName     = Protect-Text $sample.LogName
                Provider    = Protect-Text $sample.ProviderName
                EventId     = $sample.Id
                Level       = Protect-Text $sample.LevelDisplayName
                Count       = $_.Count
                MostRecent  = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            }
        })
}

$outputPath = Get-SafeOutputDirectory -Path $OutputDirectory
$generatedAt = Get-Date
$timestamp = $generatedAt.ToString('yyyyMMdd-HHmmss')

$computerSystem = $null
$operatingSystem = $null
$processors = @()
$memoryModules = @()
$videoControllers = @()
$logicalDisks = @()
$physicalDisks = @()
$storageReliability = @()
$processes = @()
$startupItems = @()
$drivers = @()
$applications = @()
$eventSummary = @()
$cacheSummary = @()
$hotFixes = @()
$defender = $null
$batteries = @()

try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem | ForEach-Object {
        [pscustomobject]@{
            Manufacturer  = Protect-Text $_.Manufacturer
            Model         = Protect-Text $_.Model
            TotalMemoryGB = Convert-BytesToGB $_.TotalPhysicalMemory
            DomainRole    = $_.DomainRole
        }
    }
} catch { Add-SectionFailure -Section 'ComputerSystem' -Exception $_.Exception }

try {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem | ForEach-Object {
        $uptime = $generatedAt - $_.LastBootUpTime
        [pscustomobject]@{
            Caption              = Protect-Text $_.Caption
            Version              = Protect-Text $_.Version
            BuildNumber          = Protect-Text $_.BuildNumber
            Architecture         = Protect-Text $_.OSArchitecture
            LastBootUpTime       = $_.LastBootUpTime
            UptimeHours          = [math]::Round($uptime.TotalHours, 1)
            FreePhysicalMemoryGB = [math]::Round(([double]$_.FreePhysicalMemory / 1MB), 2)
        }
    }
} catch { Add-SectionFailure -Section 'OperatingSystem' -Exception $_.Exception }

try {
    $processors = @(Get-CimInstance Win32_Processor | ForEach-Object {
        [pscustomobject]@{
            Name              = Protect-Text $_.Name
            Manufacturer      = Protect-Text $_.Manufacturer
            Cores             = $_.NumberOfCores
            LogicalProcessors = $_.NumberOfLogicalProcessors
            MaxClockMHz       = $_.MaxClockSpeed
            CurrentClockMHz   = $_.CurrentClockSpeed
            LoadPercentage    = $_.LoadPercentage
        }
    })
} catch { Add-SectionFailure -Section 'Processors' -Exception $_.Exception }

try {
    $memoryModules = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        [pscustomobject]@{
            CapacityGB    = Convert-BytesToGB $_.Capacity
            SpeedMHz      = $_.Speed
            ConfiguredMHz = $_.ConfiguredClockSpeed
            Manufacturer  = Protect-Text $_.Manufacturer
        }
    })
} catch { Add-SectionFailure -Section 'MemoryModules' -Exception $_.Exception }

try {
    $videoControllers = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
            Name           = Protect-Text $_.Name
            DriverVersion  = Protect-Text $_.DriverVersion
            DriverDate     = $_.DriverDate
            AdapterRAMGB   = Convert-BytesToGB $_.AdapterRAM
            VideoProcessor = Protect-Text $_.VideoProcessor
        }
    })
} catch { Add-SectionFailure -Section 'VideoControllers' -Exception $_.Exception }

try {
    $logicalDisks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        $used = if ($null -ne $_.Size -and $null -ne $_.FreeSpace) { [double]$_.Size - [double]$_.FreeSpace } else { $null }
        $usedPercent = if ($null -ne $used -and [double]$_.Size -gt 0) { [math]::Round(($used / [double]$_.Size) * 100, 1) } else { $null }
        [pscustomobject]@{
            Drive       = Protect-Text $_.DeviceID
            FileSystem  = Protect-Text $_.FileSystem
            SizeGB      = Convert-BytesToGB $_.Size
            FreeGB      = Convert-BytesToGB $_.FreeSpace
            UsedPercent = $usedPercent
        }
    })
} catch { Add-SectionFailure -Section 'LogicalDisks' -Exception $_.Exception }

try {
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $diskObjects = @(Get-PhysicalDisk)
        $physicalDisks = @($diskObjects | ForEach-Object {
            [pscustomobject]@{
                FriendlyName      = Protect-Text $_.FriendlyName
                MediaType         = Protect-Text $_.MediaType
                BusType           = Protect-Text $_.BusType
                HealthStatus      = Protect-Text $_.HealthStatus
                OperationalStatus = Protect-Text (($_.OperationalStatus -join ', '))
                SizeGB            = Convert-BytesToGB $_.Size
            }
        })

        if (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue) {
            $storageReliability = @($diskObjects | ForEach-Object {
                try {
                    $counter = $_ | Get-StorageReliabilityCounter -ErrorAction Stop
                    [pscustomobject]@{
                        FriendlyName     = Protect-Text $_.FriendlyName
                        TemperatureC     = $counter.Temperature
                        WearPercent      = $counter.Wear
                        PowerOnHours     = $counter.PowerOnHours
                        ReadErrorsTotal  = $counter.ReadErrorsTotal
                        WriteErrorsTotal = $counter.WriteErrorsTotal
                    }
                } catch {
                    [pscustomobject]@{
                        FriendlyName = Protect-Text $_.FriendlyName
                        Status       = 'Unavailable'
                    }
                }
            })
        }
    }
} catch { Add-SectionFailure -Section 'PhysicalDisks' -Exception $_.Exception }

try {
    $processes = @(Get-Process |
        Sort-Object -Property @{ Expression = { if ($null -eq $_.CPU) { 0 } else { $_.CPU } }; Descending = $true } |
        Select-Object -First $TopProcessCount |
        ForEach-Object {
            [pscustomobject]@{
                Name         = Protect-Text $_.ProcessName
                Id           = $_.Id
                CpuSeconds   = if ($null -eq $_.CPU) { 0 } else { [math]::Round($_.CPU, 1) }
                WorkingSetMB = [math]::Round(([double]$_.WorkingSet64 / 1MB), 1)
            }
        })
} catch { Add-SectionFailure -Section 'Processes' -Exception $_.Exception }

try {
    $startupItems = @(Get-CimInstance Win32_StartupCommand |
        ForEach-Object {
            [pscustomobject]@{
                Name     = Protect-Text $_.Name
                Location = Protect-Text $_.Location
            }
        } |
        Sort-Object Name -Unique)
} catch { Add-SectionFailure -Section 'StartupItems' -Exception $_.Exception }

try { $drivers = Get-SelectedDriverInventory } catch { Add-SectionFailure -Section 'Drivers' -Exception $_.Exception }
try { $applications = Get-InstalledApplications } catch { Add-SectionFailure -Section 'Applications' -Exception $_.Exception }
try { $eventSummary = Get-EventSummary -StartTime $generatedAt.AddDays(-$EventLookbackDays) } catch { Add-SectionFailure -Section 'Events' -Exception $_.Exception }

try {
    $hotFixes = @(Get-HotFix |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 20 |
        ForEach-Object {
            [pscustomobject]@{
                HotFixId    = Protect-Text $_.HotFixID
                Description = Protect-Text $_.Description
                InstalledOn = $_.InstalledOn
            }
        })
} catch { Add-SectionFailure -Section 'HotFixes' -Exception $_.Exception }

try {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $mp = Get-MpComputerStatus
        $defender = [pscustomobject]@{
            AntivirusEnabled          = $mp.AntivirusEnabled
            AntispywareEnabled        = $mp.AntispywareEnabled
            RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
            BehaviorMonitorEnabled    = $mp.BehaviorMonitorEnabled
            AntivirusSignatureAgeDays = $mp.AntivirusSignatureAge
            QuickScanAgeDays          = $mp.QuickScanAge
            FullScanAgeDays           = $mp.FullScanAge
        }
    }
} catch { Add-SectionFailure -Section 'Defender' -Exception $_.Exception }

try {
    $batteries = @(Get-CimInstance Win32_Battery -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            EstimatedChargeRemaining = $_.EstimatedChargeRemaining
            BatteryStatus            = $_.BatteryStatus
            EstimatedRunTimeMinutes  = $_.EstimatedRunTime
        }
    })
} catch { Add-SectionFailure -Section 'Battery' -Exception $_.Exception }

if (-not $SkipCacheScan) {
    $cacheTargets = @(
        [pscustomobject]@{ Label = 'UserTemp'; Path = $env:TEMP },
        [pscustomobject]@{ Label = 'WindowsTemp'; Path = (Join-Path $env:WINDIR 'Temp') },
        [pscustomobject]@{ Label = 'NpmCache'; Path = (Join-Path $env:LOCALAPPDATA 'npm-cache') },
        [pscustomobject]@{ Label = 'PipCache'; Path = (Join-Path $env:LOCALAPPDATA 'pip\Cache') },
        [pscustomobject]@{ Label = 'NuGetPackages'; Path = (Join-Path $env:USERPROFILE '.nuget\packages') },
        [pscustomobject]@{ Label = 'AdobeMediaCache'; Path = (Join-Path $env:APPDATA 'Adobe\Common\Media Cache Files') },
        [pscustomobject]@{ Label = 'BlenderCache'; Path = (Join-Path $env:LOCALAPPDATA 'Blender Foundation\Blender\Cache') }
    )

    foreach ($target in $cacheTargets) {
        try {
            $cacheSummary += Get-DirectorySizeSummary -Label $target.Label -Path $target.Path
        } catch {
            Add-SectionFailure -Section ('Cache:' + $target.Label) -Exception $_.Exception
        }
    }
}

$report = [ordered]@{
    SchemaVersion = '1.0.0'
    ScriptVersion = '1.0.2'
    GeneratedAt   = $generatedAt
    Privacy       = [ordered]@{
        Sanitized              = $true
        ComputerNameCollected  = $false
        UserNameCollected      = $false
        SerialCollected        = $false
        NetworkCollected       = $false
        EventMessagesCollected = $false
    }
    Execution = [ordered]@{
        IsAdministrator  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        EventLookbackDays = $EventLookbackDays
        CacheScanSkipped  = [bool]$SkipCacheScan
    }
    System             = $computerSystem
    OperatingSystem    = $operatingSystem
    Processors         = $processors
    MemoryModules      = $memoryModules
    VideoControllers   = $videoControllers
    LogicalDisks       = $logicalDisks
    PhysicalDisks      = $physicalDisks
    StorageReliability = $storageReliability
    TopProcesses       = $processes
    StartupItems       = $startupItems
    Drivers            = $drivers
    Applications       = $applications
    EventSummary       = $eventSummary
    CacheSummary       = $cacheSummary
    HotFixes           = $hotFixes
    Defender           = $defender
    Batteries          = $batteries
    SectionFailures    = $script:SectionFailures.ToArray()
}

$jsonFileName = 'karv-laptop-diagnostic-' + $timestamp + '.json'
$markdownFileName = 'karv-laptop-summary-' + $timestamp + '.md'
$jsonPath = Join-Path $outputPath $jsonFileName
$markdownPath = Join-Path $outputPath $markdownFileName

$json = Protect-Text ($report | ConvertTo-Json -Depth 10)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# Diagnostico KARV - resumo sanitizado')
$summaryLines.Add('')
$summaryLines.Add('- Gerado em: ' + $generatedAt.ToString('yyyy-MM-dd HH:mm:ss'))
$summaryLines.Add('- Script: 1.0.2')
$summaryLines.Add('- Secoes indisponiveis: ' + $script:SectionFailures.Count)
$summaryLines.Add('- Relatorio sem nome do computador, usuario, serial, MAC, IP ou mensagens completas de eventos.')
$summaryLines.Add('')
$summaryLines.Add('## Sistema')
if ($null -ne $computerSystem) {
    $summaryLines.Add('- Equipamento: ' + (Protect-Text $computerSystem.Manufacturer) + ' ' + (Protect-Text $computerSystem.Model))
    $summaryLines.Add('- Memoria total: ' + $computerSystem.TotalMemoryGB + ' GB')
}
if ($null -ne $operatingSystem) {
    $summaryLines.Add('- Windows: ' + (Protect-Text $operatingSystem.Caption) + ' - build ' + (Protect-Text $operatingSystem.BuildNumber))
    $summaryLines.Add('- Uptime: ' + $operatingSystem.UptimeHours + ' horas')
    $summaryLines.Add('- Memoria livre na coleta: ' + $operatingSystem.FreePhysicalMemoryGB + ' GB')
}
$summaryLines.Add('')
$summaryLines.Add('## Componentes')
foreach ($processor in $processors) {
    $summaryLines.Add('- CPU: ' + (Protect-Text $processor.Name) + ' - ' + $processor.Cores + ' nucleos / ' + $processor.LogicalProcessors + ' logicos')
}
foreach ($gpu in $videoControllers) {
    $summaryLines.Add('- GPU: ' + (Protect-Text $gpu.Name) + ' - driver ' + (Protect-Text $gpu.DriverVersion))
}
$summaryLines.Add('')
$summaryLines.Add('## Armazenamento')
foreach ($disk in $logicalDisks) {
    $summaryLines.Add('- ' + $disk.Drive + ' - ' + $disk.FreeGB + ' GB livres de ' + $disk.SizeGB + ' GB (' + $disk.UsedPercent + '% usado)')
}
foreach ($disk in $physicalDisks) {
    $summaryLines.Add('- Disco fisico: ' + (Protect-Text $disk.FriendlyName) + ' - saude ' + (Protect-Text $disk.HealthStatus))
}
$summaryLines.Add('')
$summaryLines.Add('## Inventario')
$summaryLines.Add('- Aplicativos encontrados: ' + $applications.Count)
$summaryLines.Add('- Itens de inicializacao: ' + $startupItems.Count)
$summaryLines.Add('- Drivers selecionados: ' + $drivers.Count)
$summaryLines.Add('- Grupos de eventos criticos/erro: ' + $eventSummary.Count)
$summaryLines.Add('')
$summaryLines.Add('## Proxima acao')
$summaryLines.Add('Revisar localmente o JSON e compartilhar somente os dados sanitizados solicitados para analise.')

$safeSummary = Protect-Text ($summaryLines -join [Environment]::NewLine)
[System.IO.File]::WriteAllText($markdownPath, $safeSummary, $utf8)

[pscustomobject]@{
    Status          = 'Complete'
    OutputDirectory = '%LOCALAPPDATA%\KARV\LaptopDiagnostics'
    JsonFile        = $jsonFileName
    MarkdownFile    = $markdownFileName
    SectionFailures = $script:SectionFailures.Count
}
