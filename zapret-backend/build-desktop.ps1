$ErrorActionPreference = "Stop"
Write-Host "[1/3] Cleaning..." -ForegroundColor Cyan
Remove-Item -Recurse -Force "build","dist" -ErrorAction SilentlyContinue
Remove-Item -Force "zapret-desktop.spec" -ErrorAction SilentlyContinue
Write-Host "[2/3] Building..." -ForegroundColor Cyan
$dataArgs = @("--add-data", "static;static", "--add-data", "zapret;zapret")
if (Test-Path "core") { $dataArgs += @("--add-data", "core;core") }
.venv\Scripts\pyinstaller.exe `
  --name "zapret-desktop" `
  --onefile `
  --windowed `
  --uac-admin `
  --noconfirm `
  $dataArgs `
  --hidden-import "uvicorn.logging" `
  --hidden-import "uvicorn.loops" `
  --hidden-import "uvicorn.loops.auto" `
  --hidden-import "uvicorn.protocols" `
  --hidden-import "uvicorn.protocols.http" `
  --hidden-import "uvicorn.protocols.http.auto" `
  --hidden-import "uvicorn.protocols.websockets" `
  --hidden-import "uvicorn.protocols.websockets.auto" `
  --hidden-import "uvicorn.lifespan" `
  --hidden-import "uvicorn.lifespan.on" `
  --hidden-import "webview.platforms.edgechromium" `
  --hidden-import "webview.platforms.winforms" `
  --hidden-import "engineio.async_drivers.threading" `
  --collect-submodules "webview" `
  desktop.py
Write-Host "[3/3] Result:" -ForegroundColor Cyan
if(Test-Path "dist\zapret-desktop.exe"){$size=(Get-Item "dist\zapret-desktop.exe").Length/1MB;Write-Host "SUCCESS: dist\zapret-desktop.exe ($([math]::Round($size,1)) MB)" -ForegroundColor Green}else{Write-Host FAILED -ForegroundColor Red;exit 1}
