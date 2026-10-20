[CmdletBinding()]
param(
    [ValidateSet('Install','Refresh','Remove','Status','Plan')]
    [string]$Action = 'Status',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$TaskName = 'FoxholeVivoxFix'
$InstallDir = Join-Path $env:ProgramFiles 'FoxholeVivoxFix'
$InstalledScript = Join-Path $InstallDir 'Foxhole-Vivox-Fix.ps1'
$StatePath = Join-Path $InstallDir 'routes.json'
$Endpoints = @('85.236.98.180', '85.236.98.181')
$Prefixes = @($Endpoints | ForEach-Object { $_ + '/32' })

function Get-PhysicalGateway {
    $physical = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual })
    $plans = @()
    foreach ($adapter in $physical) {
        $ipif = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
        foreach ($route in $defaults) {
            if ($route.NextHop -eq '0.0.0.0') { continue }
            $plans += [pscustomobject]@{
                InterfaceIndex = [int]$adapter.ifIndex
                InterfaceAlias = $adapter.Name
                NextHop = $route.NextHop
                Cost = [int64]$route.RouteMetric + [int64]$ipif.InterfaceMetric
            }
        }
    }
    $selected = $plans | Sort-Object Cost,InterfaceIndex | Select-Object -First 1
    if (-not $selected) { throw 'Не найден обычный шлюз Ethernet/Wi-Fi. Подключитесь к сети. VPN с kill switch может требовать другой настройки.' }
    return $selected
}

function Assert-InstallDirectory {
    if (Test-Path -LiteralPath $InstallDir) {
        if ((Get-Item -LiteralPath $InstallDir).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Каталог установки является ссылкой; установка остановлена.'
        }
        foreach ($leaf in @('Foxhole-Vivox-Fix.ps1','routes.json','refresh.lock','last-result.json')) {
            $path = Join-Path $InstallDir $leaf
            if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'В каталоге установки обнаружена ссылка; операция остановлена.'
            }
        }
    }
}

function Save-State($Routes) {
    @{ version = $Version; endpoints = $Endpoints; ownedRoutes = @($Routes) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Read-OwnedRoutes {
    if (-not (Test-Path -LiteralPath $StatePath)) { return @() }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    foreach ($entry in @($state.ownedRoutes)) {
        $parsed = $null
        if ($entry.DestinationPrefix -notin $Prefixes -or [int]$entry.InterfaceIndex -le 0 -or
            -not [Net.IPAddress]::TryParse([string]$entry.NextHop, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'Некорректное сохранённое состояние. Маршруты не изменены.'
        }
    }
    return @($state.ownedRoutes)
}

function Update-OwnedRoutes {
    Assert-InstallDirectory
    $plan = Get-PhysicalGateway
    $mutexFile = [IO.File]::Open((Join-Path $InstallDir 'refresh.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $owned = @(Read-OwnedRoutes)
        # Проверяем чужие маршруты до любых изменений. Их нельзя присваивать себе или удалять.
        foreach ($prefix in $Prefixes) {
            foreach ($route in @(Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
                $mine = @($owned | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $route.InterfaceIndex -and $_.NextHop -eq $route.NextHop })
                if ($mine.Count -eq 0 -and ($route.InterfaceIndex -ne $plan.InterfaceIndex -or $route.NextHop -ne $plan.NextHop)) {
                    throw "Уже существует другой маршрут для $prefix. Он оставлен без изменений."
                }
            }
        }
        $retained = @()
        foreach ($entry in $owned) {
            $old = @(Get-NetRoute -DestinationPrefix $entry.DestinationPrefix -InterfaceIndex $entry.InterfaceIndex -NextHop $entry.NextHop -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
            if ($entry.InterfaceIndex -ne $plan.InterfaceIndex -or $entry.NextHop -ne $plan.NextHop) {
                $old | Remove-NetRoute -Confirm:$false
            } elseif ($old.Count -gt 0) { $retained += $entry }
        }
        Save-State $retained
        foreach ($prefix in $Prefixes) {
            $existing = @(Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $plan.InterfaceIndex -NextHop $plan.NextHop -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
            if ($existing.Count -eq 0) {
                New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $plan.InterfaceIndex -NextHop $plan.NextHop -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
                $retained += [pscustomobject]@{ DestinationPrefix = $prefix; InterfaceIndex = $plan.InterfaceIndex; NextHop = $plan.NextHop }
                Save-State $retained
            }
        }
        @{ status = 'ok'; time = (Get-Date).ToString('o'); interface = $plan.InterfaceAlias; gateway = $plan.NextHop } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir 'last-result.json') -Encoding UTF8
        if (-not $Quiet) { Write-Host ('Готово. Vivox: Direct через ' + $plan.InterfaceAlias + '. Остальные подключения не изменены.') }
    } finally { $mutexFile.Dispose() }
}

function Install-Fix {
    Assert-InstallDirectory
    $null = Get-PhysicalGateway
    $priorTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($priorTask -and @($priorTask.Actions | Where-Object { $_.Arguments -like ('*' + $InstalledScript + '*') -and $_.Arguments -like '*-Action Refresh*' }).Count -eq 0) {
        throw 'Задача с таким именем уже существует и не принадлежит фиксу.'
    }
    $null = New-Item -Path $InstallDir -ItemType Directory -Force
    # SYSTEM запускает этот скрипт: обычным пользователям разрешено только чтение.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $admins = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $system = [Security.Principal.SecurityIdentifier]'S-1-5-18'
    $users = [Security.Principal.SecurityIdentifier]'S-1-5-32-545'
    $acl.SetOwner($admins)
    foreach ($sid in @($admins,$system)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $InstallDir -AclObject $acl
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force
    }
    Update-OwnedRoutes
    Register-ScheduledTask -TaskName $TaskName -Xml (Get-AutoRestoreTaskXml) -Force | Out-Null
    Write-Host 'Автовосстановление включено при запуске Windows, входе пользователя и подключении сети.'
    Write-Host 'Перезапустите Foxhole или переподключите голосовой чат. Проверьте, что слышите игроков и вас слышат.'
}

function Get-AutoRestoreTaskXml {
    $exe = [Security.SecurityElement]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $arguments = [Security.SecurityElement]::Escape(('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $InstalledScript + '" -Action Refresh -Quiet'))
    $query = [Security.SecurityElement]::Escape('<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select></Query></QueryList>')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Foxhole Vivox Fix: restore two direct routes.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT10S</Delay></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled><Delay>PT10S</Delay></LogonTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$query</Subscription><Delay>PT10S</Delay></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>$exe</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
}

function Remove-Fix {
    Assert-InstallDirectory
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and @($task.Actions | Where-Object { $_.Arguments -like ('*' + $InstalledScript + '*') -and $_.Arguments -like '*-Action Refresh*' }).Count -eq 0) {
        throw 'Задача с таким именем не принадлежит фиксу. Она оставлена без изменений.'
    }
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    foreach ($entry in @(Read-OwnedRoutes)) {
        Get-NetRoute -DestinationPrefix $entry.DestinationPrefix -InterfaceIndex $entry.InterfaceIndex -NextHop $entry.NextHop -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false
    }
    # Удаляем только собственные известные файлы, без рекурсивного удаления.
    foreach ($leaf in @('routes.json','last-result.json','refresh.lock','Foxhole-Vivox-Fix.ps1')) {
        $path = Join-Path $InstallDir $leaf
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -eq 0) {
        Remove-Item -LiteralPath $InstallDir
    }
    Write-Host 'Фикс и его автозапуск удалены. Маршруты, существовавшие до установки, сохранены.'
}

try {
    if ($Action -eq 'Plan') {
        [pscustomobject]@{ Version=$Version; Endpoints=$Endpoints; PhysicalGateway=(Get-PhysicalGateway); InstallDirectory=$InstallDir; Task=$TaskName } | ConvertTo-Json -Depth 4
        exit 0
    }
    if ($Action -eq 'Status') {
        Write-Host "Foxhole Vivox Fix $Version"
        $plan = Get-PhysicalGateway
        Write-Host ('Обычный интернет: ' + $plan.InterfaceAlias + ', шлюз ' + $plan.NextHop)
        foreach ($ip in $Endpoints) {
            $path = Find-NetRoute -RemoteIPAddress $ip
            $selected = $path | Where-Object DestinationPrefix | Select-Object -First 1
            Write-Host ($ip + ' -> ' + $selected.InterfaceAlias + ' (' + $selected.DestinationPrefix + ')')
        }
        Write-Host ('Автовосстановление: ' + [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
        Write-Host 'Эта проверка показывает маршрут. Работу микрофона и звука проверяйте в игре.'
        exit 0
    }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Action
        $process = Start-Process -FilePath $exe -Verb RunAs -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
        exit $process.ExitCode
    }
    switch ($Action) {
        'Install' { Install-Fix }
        'Refresh' {
            if (-not (Test-Path -LiteralPath $InstalledScript)) { throw 'Сначала запустите Install.cmd.' }
            Update-OwnedRoutes
        }
        'Remove' { Remove-Fix }
    }
} catch {
    if ($Quiet -and (Test-Path -LiteralPath $InstallDir)) {
        @{status='error';time=(Get-Date).ToString('o');message=$_.Exception.Message} | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $InstallDir 'last-result.json') -Encoding UTF8
    } else { Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
    exit 1
}
