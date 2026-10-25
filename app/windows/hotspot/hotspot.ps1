# Karing+ hotspot helper (Windows Mobile Hotspot through WinRT). Prints one JSON object.
# Usage: hotspot.ps1 -Action status|start|stop|configure|profiles [-Source profile] [-Ssid s] [-Pass p] [-Band auto|2.4|5]
param([string]$Action = "status", [string]$Source = "", [string]$Ssid = "", [string]$Pass = "", [string]$Band = "")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Out-Json($o) { $o | ConvertTo-Json -Compress -Depth 4 }
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
  # IAsyncAction (no result), for example ConfigureAccessPointAsync.
  $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
  function AwaitAction($op) { $task = $asTaskAction.Invoke($null, @($op)); $task.Wait(-1) | Out-Null }
  $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
  $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
  $all = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
  if ($Action -eq "profiles") {
    $list = @($all | Where-Object { "$($_.GetNetworkConnectivityLevel())" -ne "None" } | ForEach-Object {
      @{ name = $_.ProfileName; level = "$($_.GetNetworkConnectivityLevel())" } })
    $cur = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    Out-Json @{ ok = $true; profiles = $list; internet = $(if ($cur) { $cur.ProfileName } else { "" }) }; exit 0
  }
  # The connection whose internet is shared: the one asked for, otherwise the current internet connection.
  $profile = $null
  if ($Source -ne "") { $profile = $all | Where-Object { $_.ProfileName -eq $Source } | Select-Object -First 1 }
  if ($null -eq $profile) { $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() }
  if ($null -eq $profile) { Out-Json @{ ok = $false; error = "no internet connection" }; exit 0 }
  $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
  $cfg = $tm.GetCurrentAccessPointConfiguration()
  switch ($Action) {
    "configure" {
      if ($Ssid -ne "") { $cfg.Ssid = $Ssid }
      if ($Pass -ne "") { $cfg.Passphrase = $Pass }
      if ($Band -ne "") {
        $b = switch ($Band) { "2.4" { "TwoPointFourGigahertz" } "5" { "FiveGigahertz" } default { "Auto" } }
        try { $cfg.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::$b } catch {}
      }
      AwaitAction ($tm.ConfigureAccessPointAsync($cfg))
    }
    "start" {
      $r = Await ($tm.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
      if ($r.Status -ne "Success") { Out-Json @{ ok = $false; error = "$($r.Status) $($r.AdditionalErrorMessage)" }; exit 0 }
    }
    "stop" {
      $r = Await ($tm.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
      if ($r.Status -ne "Success") { Out-Json @{ ok = $false; error = "$($r.Status) $($r.AdditionalErrorMessage)" }; exit 0 }
    }
  }
  $cfg = $tm.GetCurrentAccessPointConfiguration()
  $band = "auto"; try { $band = switch ("$($cfg.Band)") { "TwoPointFourGigahertz" { "2.4" } "FiveGigahertz" { "5" } default { "auto" } } } catch {}
  Out-Json @{ ok = $true; state = "$($tm.TetheringOperationalState)"; ssid = $cfg.Ssid; pass = $cfg.Passphrase; band = $band;
              clients = $tm.ClientCount; maxClients = $tm.MaxClientCount; source = $profile.ProfileName }
} catch {
  Out-Json @{ ok = $false; error = $_.Exception.Message }
}
