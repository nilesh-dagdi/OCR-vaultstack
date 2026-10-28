$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runDir = Join-Path $dir '.run'
foreach ($name in @('ssh.pid', 'web.pid')) {
  $f = Join-Path $runDir $name
  if (Test-Path -LiteralPath $f) {
    $procId = Get-Content -LiteralPath $f | Select-Object -First 1
    try {
      Stop-Process -Id ([int]$procId) -Force -ErrorAction Stop
      Write-Host "stopped $name (pid $procId)"
    } catch {
      Write-Host "$name (pid $procId) was not running"
    }
    Remove-Item -LiteralPath $f -Force
  } else {
    Write-Host "$name not found"
  }
}
