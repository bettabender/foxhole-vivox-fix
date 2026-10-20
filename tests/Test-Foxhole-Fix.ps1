$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\Foxhole-Vivox-Fix.ps1'
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source).Path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Source parse failed.' }
foreach ($fn in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $fn.Extent.Text
}
$Version='test'; $TaskName='FoxholeVivoxFix'; $InstalledScript='C:\Program Files\FoxholeVivoxFix\Foxhole-Vivox-Fix.ps1'
$Endpoints=@('85.236.98.180','85.236.98.181'); $Prefixes=@($Endpoints|ForEach-Object{$_+'/32'}); $Quiet=$true
$scheduler = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$definition = $scheduler.NewTask(0)
$definition.XmlText = Get-AutoRestoreTaskXml
$taskAccount = New-Object Security.Principal.NTAccount($definition.Principal.UserId)
$taskSid = $taskAccount.Translate([Security.Principal.SecurityIdentifier]).Value
if ($definition.Triggers.Count -ne 3 -or $taskSid -ne 'S-1-5-18') { throw 'Task XML validation failed.' }
'PASS: task definition accepted by Windows Task Scheduler; no task registered.'

function Get-NetAdapter { [CmdletBinding()]param([switch]$Physical) [pscustomobject]@{ifIndex=9;Name='Ethernet';Status='Up';Virtual=$false} }
function Get-NetIPInterface { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) [pscustomobject]@{InterfaceMetric=25} }
function Get-NetRoute {
    [CmdletBinding()]param($DestinationPrefix,$InterfaceIndex,$NextHop,$AddressFamily,$PolicyStore)
    if ($DestinationPrefix -eq '0.0.0.0/0') { return [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=9;NextHop=$script:Gateway;RouteMetric=0} }
    foreach($route in @($script:Routes)) {
        if ($route.DestinationPrefix -ne $DestinationPrefix) { continue }
        if ($PSBoundParameters.ContainsKey('InterfaceIndex') -and $route.InterfaceIndex -ne $InterfaceIndex) { continue }
        if ($PSBoundParameters.ContainsKey('NextHop') -and $route.NextHop -ne $NextHop) { continue }
        $route
    }
}
function New-NetRoute {
    [CmdletBinding()]param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore)
    if ($PolicyStore -ne 'ActiveStore' -or $DestinationPrefix -notin $Prefixes) { throw 'Unexpected route mutation.' }
    $script:Added++
    $script:Routes += [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric}
}
function Remove-NetRoute {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        $script:Removed++
        $script:Routes=@($script:Routes|Where-Object { -not ($_.DestinationPrefix -eq $InputObject.DestinationPrefix -and $_.InterfaceIndex -eq $InputObject.InterfaceIndex -and $_.NextHop -eq $InputObject.NextHop) })
    }
}
function Reset-Case([string]$Name) {
    $script:InstallDir=Join-Path $PSScriptRoot ('fix-tests\'+$Name+'-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -Path $script:InstallDir -ItemType Directory -Force
    $script:StatePath=Join-Path $script:InstallDir 'routes.json'
    $script:Routes=@();$script:Gateway='192.168.50.1';$script:Added=0;$script:Removed=0
}
Reset-Case 'fresh'
Update-OwnedRoutes
if ($Routes.Count -ne 2 -or $Added -ne 2 -or @(Read-OwnedRoutes).Count -ne 2) { throw 'Fresh install failed.' }
Update-OwnedRoutes
if ($Added -ne 2 -or $Removed -ne 0) { throw 'Repeat must not duplicate routes.' }
'PASS: fresh apply and repeated apply.'
$Gateway='192.168.60.1';Update-OwnedRoutes
if ($Routes.Count -ne 2 -or $Added -ne 4 -or $Removed -ne 2 -or @($Routes|Where-Object NextHop -ne $Gateway).Count) { throw 'Gateway change failed.' }
'PASS: gateway change replaces only owned routes.'
$Routes=@();Update-OwnedRoutes
if ($Routes.Count -ne 2 -or @(Read-OwnedRoutes).Count -ne 2) { throw 'Reboot recovery failed.' }
'PASS: empty ActiveStore recovery.'
Reset-Case 'preexisting'
$Routes=@([pscustomobject]@{DestinationPrefix=$Prefixes[0];InterfaceIndex=9;NextHop=$Gateway;RouteMetric=1})
Update-OwnedRoutes
if ($Added -ne 1 -or @(Read-OwnedRoutes).Count -ne 1 -or (Read-OwnedRoutes).DestinationPrefix -ne $Prefixes[1]) { throw 'Preexisting route was claimed.' }
'PASS: correct preexisting route is preserved without claiming ownership.'
Reset-Case 'conflict'
$Routes=@([pscustomobject]@{DestinationPrefix=$Prefixes[0];InterfaceIndex=20;NextHop='10.9.0.1';RouteMetric=1})
$failed=$false
try { Update-OwnedRoutes } catch { $failed=$true }
if (-not $failed -or $Added -ne 0 -or $Removed -ne 0 -or $Routes.Count -ne 1) { throw 'Conflict protection failed.' }
'PASS: conflicting preexisting route blocks changes.'
'All tests passed. Real system routes, tasks and installation were not modified.'
