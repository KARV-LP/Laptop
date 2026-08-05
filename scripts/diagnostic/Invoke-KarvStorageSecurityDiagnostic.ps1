#requires -Version 5.1
<#+
.SYNOPSIS
    Collects a sanitized, read-only storage and antimalware investigation.
.DESCRIPTION
    Reads structured disk events, storage mappings, Windows Security Center,
    AVG/Avast services and processes, and Microsoft Defender status. The only
    local effect is writing reports to the output directory. It does not repair,
    clean, configure, restart, install, remove, or transmit data.
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'),
    [ValidateRange(1, 90)]
    [int]$EventLookbackDays = 30,
    [ValidateRange(1, 200)]
    [int]$MaxDiskEvents = 100
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
    $text = [regex]::Replace($text, '(?i)\bS-1-\d+(?:-\d+)+\b', '<SID>')
    $text = [regex]::Replace($text, '(?i)\b[A-F0-9]{2}(?:[:-][A-F0-9]{2}){5}\b', '<MAC>')
    $text = [regex]::Replace($text, '(?i)\b[\w.%+-]+@[\w.-]+\.[A-Z]{2,}\b', '<EMAIL>')

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

function Convert-EventPropertyValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) { return 'BinaryLength=' + $Value.Length }
    if ($Value -is [Array]) { return 'ArrayLength=' + $Value.Count }
    return Protect-Text $Value
}

function Get-InstalledSecurityApplications {
    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = foreach ($registryPath in $registryPaths) {
        Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                $name = Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName'
                if (-not [string]::IsNullOrWhiteSpace([string]$name) -and [string]$name -match '(?i)AVG|Avast') {
                    [pscustomobject]@{
                        Name      = Protect-Text $name
                        Version   = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayVersion')
                        Publisher = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'Publisher')
                    }
                }
            }
    }

    return @($items | Sort-Object Name, Version, Publisher -Unique)
}

$outputPath = Get-SafeOutputDirectory -Path $OutputDirectory
$generatedAt = Get-Date
$timestamp = $generatedAt.ToString('yyyyMMdd-HHmmss')
$startTime = $generatedAt.AddDays(-$EventLookbackDays)

$diskInventory = @()
$diskDriveInventory = @()
$partitionInventory = @()
$volumeInventory = @()
$storageControllers = @()
$diskEvents = @()
$diskEventDevices = @()
$securityCenterProducts = @()
$securityCenterStatus = 'NotQueried'
$securityServices = @()
$securityProcesses = @()
$securityApplications = @()
$defender = $null
$defenderStatus = 'NotQueried'

try {
    $diskInventory = @(Get-Disk -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Number            = $_.Number
            FriendlyName      = Protect-Text $_.FriendlyName
            BusType           = Protect-Text $_.BusType
            PartitionStyle    = Protect-Text $_.PartitionStyle
            HealthStatus      = Protect-Text $_.HealthStatus
            OperationalStatus = Protect-Text (($_.OperationalStatus -join ', '))
            SizeGB            = Convert-BytesToGB $_.Size
            IsBoot            = $_.IsBoot
            IsSystem          = $_.IsSystem
            IsOffline         = $_.IsOffline
            IsReadOnly        = $_.IsReadOnly
        }
    } | Sort-Object Number)
} catch { Add-SectionFailure -Section 'DiskInventory' -Exception $_.Exception }

try {
    $diskDriveInventory = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Index         = $_.Index
            Model         = Protect-Text $_.Model
            InterfaceType = Protect-Text $_.InterfaceType
            Status        = Protect-Text $_.Status
            SizeGB        = Convert-BytesToGB $_.Size
            Partitions    = $_.Partitions
        }
    } | Sort-Object Index)
} catch { Add-SectionFailure -Section 'DiskDriveInventory' -Exception $_.Exception }

try {
    $partitionInventory = @(Get-Partition -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            DiskNumber      = $_.DiskNumber
            PartitionNumber = $_.PartitionNumber
            DriveLetter     = Protect-Text $_.DriveLetter
            Type            = Protect-Text $_.Type
            SizeGB          = Convert-BytesToGB $_.Size
            IsBoot          = $_.IsBoot
            IsSystem        = $_.IsSystem
        }
    } | Sort-Object DiskNumber, PartitionNumber)
} catch { Add-SectionFailure -Section 'PartitionInventory' -Exception $_.Exception }

try {
    $volumeInventory = @(Get-Volume -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            DriveLetter       = Protect-Text $_.DriveLetter
            FileSystem        = Protect-Text $_.FileSystem
            HealthStatus      = Protect-Text $_.HealthStatus
            OperationalStatus = Protect-Text (($_.OperationalStatus -join ', '))
            SizeGB            = Convert-BytesToGB $_.Size
            FreeGB            = Convert-BytesToGB $_.SizeRemaining
        }
    } | Sort-Object DriveLetter)
} catch { Add-SectionFailure -Section 'VolumeInventory' -Exception $_.Exception }

try {
    $controllerItems = @()
    $controllerItems += @(Get-CimInstance Win32_SCSIController -ErrorAction SilentlyContinue)
    $controllerItems += @(Get-CimInstance Win32_IDEController -ErrorAction SilentlyContinue)
    $storageControllers = @($controllerItems | ForEach-Object {
        [pscustomobject]@{
            Name         = Protect-Text $_.Name
            Manufacturer = Protect-Text $_.Manufacturer
            Status       = Protect-Text $_.Status
        }
    } | Sort-Object Name -Unique)
} catch { Add-SectionFailure -Section 'StorageControllers' -Exception $_.Exception }

try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'disk'
        Id           = 11
        StartTime    = $startTime
    } -MaxEvents $MaxDiskEvents -ErrorAction Stop)

    $diskEvents = @($events | ForEach-Object {
        $propertyValues = @($_.Properties | Select-Object -First 4 | ForEach-Object {
            Convert-EventPropertyValue $_.Value
        })

        $deviceReference = if ($propertyValues.Count -gt 0) { [string]$propertyValues[0] } else { $null }
        $deviceNumberHint = $null
        if (-not [string]::IsNullOrWhiteSpace($deviceReference)) {
            $match = [regex]::Match($deviceReference, '(?i)Harddisk(\d+)')
            if ($match.Success) { $deviceNumberHint = [int]$match.Groups[1].Value }
        }

        [pscustomobject]@{
            TimeCreated      = $_.TimeCreated
            RecordId         = $_.RecordId
            Provider         = Protect-Text $_.ProviderName
            EventId          = $_.Id
            Level            = Protect-Text $_.LevelDisplayName
            DeviceReference  = Protect-Text $deviceReference
            DeviceNumberHint = $deviceNumberHint
            PropertyCount    = @($_.Properties).Count
            PropertyValues   = $propertyValues
        }
    } | Sort-Object TimeCreated -Descending)
} catch {
    if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
        $diskEvents = @()
    } else {
        Add-SectionFailure -Section 'DiskEvents' -Exception $_.Exception
    }
}

$diskEventDevices = @($diskEvents |
    Group-Object DeviceReference, DeviceNumberHint |
    ForEach-Object {
        $sample = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            DeviceReference  = $sample.DeviceReference
            DeviceNumberHint = $sample.DeviceNumberHint
            Count            = $_.Count
            MostRecent       = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        }
    } |
    Sort-Object Count -Descending)

try {
    $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop)
    $securityCenterProducts = @($products | ForEach-Object {
        $productState = [int](Get-OptionalPropertyValue -InputObject $_ -Name 'productState')
        [pscustomobject]@{
            DisplayName  = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'displayName')
            ProductState = $productState
            StateHex     = ('0x{0:X6}' -f $productState)
            Timestamp    = Protect-Text (Get-OptionalPropertyValue -InputObject $_ -Name 'timestamp')
        }
    } | Sort-Object DisplayName)
    $securityCenterStatus = 'Available'
} catch {
    $securityCenterStatus = 'Unavailable'
}

try {
    $services = @(Get-Service -ErrorAction Stop)
    $securityServices = @($services |
        Where-Object {
            $_.Name -in @('wscsvc', 'SecurityHealthService', 'WinDefend') -or
            $_.Name -match '(?i)^(avg|avast)' -or
            $_.DisplayName -match '(?i)AVG|Avast'
        } |
        ForEach-Object {
            [pscustomobject]@{
                Name        = Protect-Text $_.Name
                DisplayName = Protect-Text $_.DisplayName
                Status      = Protect-Text $_.Status
                StartType   = Protect-Text $_.StartType
            }
        } |
        Sort-Object Name -Unique)
} catch { Add-SectionFailure -Section 'SecurityServices' -Exception $_.Exception }

try {
    $securityProcesses = @(Get-Process -ErrorAction Stop |
        Where-Object { $_.ProcessName -match '(?i)^(avg|avast)' } |
        ForEach-Object {
            [pscustomobject]@{
                Name         = Protect-Text $_.ProcessName
                Id           = $_.Id
                CpuSeconds   = if ($null -eq $_.CPU) { 0 } else { [math]::Round($_.CPU, 1) }
                WorkingSetMB = [math]::Round(([double]$_.WorkingSet64 / 1MB), 1)
            }
        } |
        Sort-Object Name, Id)
} catch { Add-SectionFailure -Section 'SecurityProcesses' -Exception $_.Exception }

try { $securityApplications = Get-InstalledSecurityApplications } catch { Add-SectionFailure -Section 'SecurityApplications' -Exception $_.Exception }

try {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $defender = [pscustomobject]@{
            AntivirusEnabled          = $mp.AntivirusEnabled
            AntispywareEnabled        = $mp.AntispywareEnabled
            RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
            BehaviorMonitorEnabled    = $mp.BehaviorMonitorEnabled
            AntivirusSignatureAgeDays = $mp.AntivirusSignatureAge
        }
        $defenderStatus = 'Available'
    } else {
        $defenderStatus = 'CommandUnavailable'
    }
} catch {
    $defenderStatus = 'Unavailable'
}

$report = [ordered]@{
    SchemaVersion = '1.0.0'
    ScriptVersion = '1.0.0'
    Collector     = 'StorageSecurity'
    GeneratedAt   = $generatedAt
    Privacy       = [ordered]@{
        Sanitized              = $true
        ComputerNameCollected  = $false
        UserNameCollected      = $false
        SidCollected           = $false
        SerialCollected        = $false
        NetworkCollected       = $false
        EventMessagesCollected = $false
        SecurityPathsCollected = $false
        SecurityGuidsCollected = $false
    }
    Execution = [ordered]@{
        IsAdministrator   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        EventLookbackDays = $EventLookbackDays
        MaxDiskEvents     = $MaxDiskEvents
    }
    DiskInventory          = $diskInventory
    DiskDriveInventory     = $diskDriveInventory
    PartitionInventory     = $partitionInventory
    VolumeInventory        = $volumeInventory
    StorageControllers     = $storageControllers
    DiskEvents             = $diskEvents
    DiskEventDevices       = $diskEventDevices
    SecurityCenterStatus   = $securityCenterStatus
    SecurityCenterProducts = $securityCenterProducts
    SecurityServices       = $securityServices
    SecurityProcesses      = $securityProcesses
    SecurityApplications   = $securityApplications
    DefenderStatus         = $defenderStatus
    Defender               = $defender
    SectionFailures        = $script:SectionFailures.ToArray()
}

$jsonFileName = 'karv-storage-security-' + $timestamp + '.json'
$markdownFileName = 'karv-storage-security-summary-' + $timestamp + '.md'
$jsonPath = Join-Path $outputPath $jsonFileName
$markdownPath = Join-Path $outputPath $markdownFileName
$utf8 = New-Object System.Text.UTF8Encoding($false)

$json = Protect-Text ($report | ConvertTo-Json -Depth 10)
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# KARV - investigacao de armazenamento e seguranca')
$summaryLines.Add('')
$summaryLines.Add('- Gerado em: ' + $generatedAt.ToString('yyyy-MM-dd HH:mm:ss'))
$summaryLines.Add('- Script: 1.0.0')
$summaryLines.Add('- Eventos disk ID 11: ' + $diskEvents.Count)
$summaryLines.Add('- Referencias de dispositivo: ' + $diskEventDevices.Count)
$summaryLines.Add('- Produtos antivirus registrados: ' + $securityCenterProducts.Count)
$summaryLines.Add('- Servicos de seguranca encontrados: ' + $securityServices.Count)
$summaryLines.Add('- Processos AVG/Avast encontrados: ' + $securityProcesses.Count)
$summaryLines.Add('- Secoes indisponiveis: ' + $script:SectionFailures.Count)
$summaryLines.Add('- Sem mensagens completas de eventos, serial, SID, caminhos de seguranca, GUIDs ou dados de rede.')

$safeSummary = Protect-Text ($summaryLines -join [Environment]::NewLine)
[System.IO.File]::WriteAllText($markdownPath, $safeSummary, $utf8)

[pscustomobject]@{
    Status                 = 'Complete'
    OutputDirectory        = '%LOCALAPPDATA%\KARV\LaptopDiagnostics'
    JsonFile               = $jsonFileName
    MarkdownFile           = $markdownFileName
    DiskEventCount         = $diskEvents.Count
    SecurityProductCount   = $securityCenterProducts.Count
    SectionFailures        = $script:SectionFailures.Count
}
