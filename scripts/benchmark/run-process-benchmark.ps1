#!/usr/bin/env pwsh
# Unified benchmark runner (Windows)
# - Starts a local target server
# - Drives load through the target proxy
# - Samples process WorkingSet/CPU
# Results go to benchmark_results/metrics_<process>_<timestamp>.txt

param(
  [string]$ProcessName = "cheddarproxy",
  [int]$ProcessId,
  [int]$ProxyPort = 9090,
  [string]$Target = "http://127.0.0.1:8001/",
  [int]$Duration = 300,
  [int]$Interval = 5,
  [int]$SleepMs = 20,  # ~50 req/s (used if step pattern disabled)
  [switch]$UseStepPattern = $true,
  [string]$StepPattern = "100,60 40,90 20,90 10,90 5,90 100,60" # sleep_ms,duration_s
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$ResultsDir = Join-Path $Root "benchmark_results"
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

Write-Host "Process:      $ProcessName"
if ($PSBoundParameters.ContainsKey('ProcessId')) { Write-Host "Process PID:  $ProcessId" }
Write-Host "Proxy port:   $ProxyPort"
Write-Host "Target:       $Target"
Write-Host "Duration:     $Duration s"
Write-Host "Sample every: $Interval s"
Write-Host "Load sleep:   ${SleepMs}ms (~50 req/s) (used if step pattern off)"
Write-Host "Step pattern: $($UseStepPattern.IsPresent ? $StepPattern : 'disabled')"
Write-Host ""

$serverJob = $null
$loadJob = $null
$countFile = [System.IO.Path]::GetTempFileName()
$loadStart = Get-Date

try {
  # Basic proxy reachability check (best effort)
  try {
    $reachable = Test-NetConnection -ComputerName 127.0.0.1 -Port $ProxyPort -InformationLevel Quiet
    if (-not $reachable) {
      Write-Host "❌ Proxy not reachable on 127.0.0.1:$ProxyPort. Start it or set -ProxyPort." -ForegroundColor Red
      return
    }
  } catch {}

  if ($PSBoundParameters.ContainsKey('ProcessId')) {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
      Write-Host "❌ PID $ProcessId not found. Start the process or update -ProcessId." -ForegroundColor Red
      return
    }
  }

  # 1) Start local target server
  Write-Host "Starting local target server on 127.0.0.1:8001 ..."
  $serverJob = Start-Job { python -m http.server 8001 *> $null }
  Start-Sleep -Seconds 1

# 2) Start load generator
Write-Host "Starting load generator through proxy $ProxyPort ..."
  if ($UseStepPattern) {
    $loadJob = Start-Job -ScriptBlock {
      param($TargetUrl, $Proxy, $Pattern, $CountFile)
      $count = 0
      foreach ($step in $Pattern.Split(" ")) {
        if (-not $step) { continue }
        $parts = $step.Split(",")
        if ($parts.Count -ne 2) { continue }
        $sleepMs = [int]$parts[0]
        $durationS = [int]$parts[1]
        $stopStep = (Get-Date).AddSeconds($durationS)
        Write-Host "  Step: sleep=${sleepMs}ms (~$([math]::Floor(1000/$sleepMs)) req/s), duration=${durationS}s"
        while ((Get-Date) -lt $stopStep) {
          try {
            curl.exe --proxy $Proxy $TargetUrl *> $null
            $count++
          } catch {}
          Start-Sleep -Milliseconds $sleepMs
        }
      }
      Set-Content -Path $CountFile -Value $count -Force
    } -ArgumentList $Target, "http://127.0.0.1:$ProxyPort", $StepPattern, $countFile
  } else {
    $stopAt = (Get-Date).AddSeconds($Duration)
    $loadJob = Start-Job -ScriptBlock {
      param($TargetUrl, $Proxy, $StopAt, $SleepMs, $CountFile)
      $count = 0
      while ((Get-Date) -lt $StopAt) {
        try {
          curl.exe --proxy $Proxy $TargetUrl *> $null
          $count++
        } catch {}
        Start-Sleep -Milliseconds $SleepMs
      }
      Set-Content -Path $CountFile -Value $count -Force
    } -ArgumentList $Target, "http://127.0.0.1:$ProxyPort", $stopAt, $SleepMs, $countFile
  }

  # 3) Sample process metrics
  Write-Host "Sampling process metrics..."
  if ($PSBoundParameters.ContainsKey('ProcessId')) {
    python "$ScriptDir\benchmark_process_metrics.py" `
      --pid $ProcessId `
      --duration $Duration `
      --interval $Interval `
      --proxy-port $ProxyPort
  } else {
    python "$ScriptDir\benchmark_process_metrics.py" `
      --process-name "$ProcessName" `
      --duration $Duration `
      --interval $Interval `
      --proxy-port $ProxyPort
  }

} finally {
  if ($loadJob) { Stop-Job $loadJob -Force; Remove-Job $loadJob }
  if ($serverJob) { Stop-Job $serverJob -Force; Remove-Job $serverJob }
  $loadEnd = Get-Date
  if (Test-Path $countFile) {
    $total = Get-Content $countFile | Select-Object -First 1
    $elapsed = ($loadEnd - $loadStart).TotalSeconds
    if ($elapsed -gt 0) {
      $rps = [math]::Round($total / $elapsed, 2)
      $summary = "Throughput summary: requests=$total, elapsed=$([math]::Round($elapsed,2))s, avg_rps=$rps"
      Write-Host $summary
      $latest = Get-ChildItem -Path $ResultsDir -Filter "metrics_*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($latest) {
        Add-Content -Path $latest.FullName -Value $summary
      }
    }
  }
  Remove-Item $countFile -ErrorAction SilentlyContinue
}

Write-Host "Done. Logs are in $ResultsDir."
