$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runDir = Join-Path $dir '.run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

function Test-Port([int]$port) {
  try { return (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) }
  catch { return $false }
}

if (Test-Port 8094) {
  Write-Host 'tunnel already up on 127.0.0.1:8094'
} else {
  $ssh = Start-Process ssh -ArgumentList @('-N', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=30',
    '-L', '8094:100.105.243.101:8094', 'nilesh@vaultstackai') -PassThru -WindowStyle Hidden
  Set-Content -LiteralPath (Join-Path $runDir 'ssh.pid') -Value $ssh.Id
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Port 8094) { break }
  }
  if (Test-Port 8094) { Write-Host "tunnel up (ssh pid $($ssh.Id))" }
  else { Write-Warning 'tunnel did not come up - run ssh manually and check your key' }
}

if (Test-Port 5500) {
  Write-Host 'web server already up on 127.0.0.1:5500'
} else {
  $py = (Get-Command python -ErrorAction SilentlyContinue).Source
  if (-not $py) { throw 'python not found on PATH' }
  $web = Start-Process $py -ArgumentList @('-m', 'http.server', '5500', '--bind', '127.0.0.1') `
    -WorkingDirectory $dir -PassThru -WindowStyle Hidden
  Set-Content -LiteralPath (Join-Path $runDir 'web.pid') -Value $web.Id
  Start-Sleep -Seconds 2
  if (Test-Port 5500) { Write-Host "web server up (python pid $($web.Id))" }
  else { throw 'web server failed to start' }
}

Write-Host ''
Write-Host 'OCR status:'
try {
  $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8094/health' -TimeoutSec 10
  Write-Host ("  {0}{1}" -f $h.status, $(if ($h.error) { ' - ' + $h.error } else { '' }))
  if ($h.status -ne 'ready') { Write-Host '  (engine warms up for ~2 min; the page shows an amber dot until then)' }
} catch {
  Write-Host '  no answer from the API yet'
}

Write-Host ''
Write-Host 'Opening http://localhost:5500'
Start-Process 'http://localhost:5500/'
