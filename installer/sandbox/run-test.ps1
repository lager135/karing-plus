# Runs inside Windows Sandbox: silent install, checks, silent update over it, checks.
# Results go to C:\test\result.txt (the host's D:\dock\karingplus-installer\sandbox\result.txt).
$out = "C:\test\result.txt"
"Karing+ installer test $(Get-Date)" | Out-File $out -Encoding utf8
$setup = Get-ChildItem C:\dist -Filter "Karing+-*-Setup.exe" | Sort-Object LastWriteTime | Select-Object -Last 1
"setup: $($setup.Name)" | Out-File $out -Append -Encoding utf8

function Check($step) {
    $key = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KaringPlus"
    $reg = Get-ItemProperty $key -ErrorAction SilentlyContinue
    $dir = "$env:ProgramFiles\Karing+"
    "[$step] exe=$(Test-Path "$dir\karing.exe") service=$(Test-Path "$dir\karingService.exe") zapret=$(Test-Path "$dir\zapret") " +
    "uninstaller=$(Test-Path "$dir\uninstall.exe") desktop=$(Test-Path "$env:PUBLIC\Desktop\Karing+.lnk") " +
    "version=$($reg.DisplayVersion) running=$([bool](Get-Process karing -ErrorAction SilentlyContinue))" | Out-File $out -Append -Encoding utf8
}

$p = Start-Process $setup.FullName -ArgumentList "/S" -Wait -PassThru
"install exit=$($p.ExitCode)" | Out-File $out -Append -Encoding utf8
Start-Sleep 5
Check "install"

$p = Start-Process $setup.FullName -ArgumentList "/S" -Wait -PassThru
"update exit=$($p.ExitCode)" | Out-File $out -Append -Encoding utf8
Start-Sleep 5
Check "update"

Get-Content "$env:TEMP\KaringPlus-Setup.log" -ErrorAction SilentlyContinue | Out-File $out -Append -Encoding utf8
"done" | Out-File $out -Append -Encoding utf8
