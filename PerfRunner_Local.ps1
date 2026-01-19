# ==========================================================
# PerfRunner_Local.ps1
# Run LOCALLY on: MIGTEST2, NETAPP2ANF, SCCMPRDFS01
# Creates a per-runner CSV in \\sccmprdfs01\f$\PerfStage\CentralResults
# ==========================================================

# -------------------- SETTINGS --------------------
$CentralResults = "\\sccmprdfs01\f$\PerfStage\CentralResults"
$CentralLogs    = "\\sccmprdfs01\f$\PerfStage\CentralLogs"

$TestSizeGB  = 10
$Iterations  = 3
$CleanupTemp = $true

# Sources you wanted (script will SKIP if not reachable from this runner)
$UncSources = @(
  @{ Name="ONPREM_F$"; Path="\\sccmprdfs01\f$" },
  @{ Name="AZURE_C$" ; Path="\\10.210.88.4\c$" }
)

# Destinations (ANF + ESAN)
$Destinations = @(
  @{ Name="ESAN"; Path="\\emuprdfs01.uhb.downstate.org\e$" },
  @{ Name="ANF" ; Path="\\dmcanfapp-e0bc.uhb.downstate.org\NatusPrd" }
)

# -------------------- SETUP --------------------
New-Item -ItemType Directory -Path $CentralResults,$CentralLogs -Force | Out-Null

$Runner = $env:COMPUTERNAME
$RunnerIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
  Select-Object -ExpandProperty IPAddress -Unique) -join ", "

# Per-runner stage on central share (prevents collisions)
$StageRoot = Join-Path $CentralResults ("Stage_" + $Runner)
$StageSrc  = Join-Path $StageRoot "stage_src"
$StageOut  = Join-Path $StageRoot "stage_out"
$LogsDir   = Join-Path $CentralLogs  $Runner
New-Item -ItemType Directory -Path $StageRoot,$StageSrc,$StageOut,$LogsDir -Force | Out-Null

function Get-UncServer {
  param([string]$Path)
  if ($Path -match '^[\\]{2}([^\\]+)') { return $Matches[1] }
  return $null
}

function Resolve-IPv4 {
  param([string]$HostOrIp)
  try {
    if ([string]::IsNullOrWhiteSpace($HostOrIp)) { return @() }
    if ($HostOrIp -match '^\d{1,3}(\.\d{1,3}){3}$') { return @($HostOrIp) }
    [System.Net.Dns]::GetHostAddresses($HostOrIp) |
      Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
      ForEach-Object { $_.IPAddressToString } | Select-Object -Unique
  } catch { @() }
}

function Ensure-Writeable {
  param([string]$Root)
  try {
    $t = Join-Path $Root ("_PERFTEST_" + $Runner + "_WRITECHK")
    New-Item -ItemType Directory -Path $t -Force -ErrorAction Stop | Out-Null
    Remove-Item $t -Force -Recurse -ErrorAction Stop
    return $true
  } catch {
    Write-Warning ("Not writeable: {0}  Error: {1}" -f $Root, $_.Exception.Message)
    return $false
  }
}

function New-TestFile {
  param([string]$FilePath, [int]$SizeGB)
  if (Test-Path $FilePath) { Remove-Item $FilePath -Force -ErrorAction SilentlyContinue }
  $bytes = $SizeGB * 1GB
  $fs = [System.IO.File]::Open($FilePath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
  try { $fs.SetLength($bytes) } finally { $fs.Close() }
  if (-not (Test-Path $FilePath)) { throw "Failed to create file: $FilePath" }
}

function Invoke-RobocopyTimed {
  param([string]$SourceDir,[string]$DestDir,[string]$FileName,[string]$Tag)

  New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
  $log = Join-Path $LogsDir ("robocopy_{0}_{1}.log" -f $Tag,(Get-Date -Format "yyyyMMdd_HHmmss_fff"))

  $args = @(
    "`\"$SourceDir`\"", "`\"$DestDir`\"", "`\"$FileName`\"",
    "/NP","/R:0","/W:0","/TEE","/NFL","/NDL",
    "/LOG:`\"$log`\""
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & robocopy @args
  $rc = $LASTEXITCODE
  $sw.Stop()

  [PSCustomObject]@{
    Seconds  = $sw.Elapsed.TotalSeconds
    ExitCode = $rc
    Success  = ($rc -lt 8)
    LogPath  = $log
  }
}

Write-Host ("RUNNER: {0}  IPs: {1}" -f $Runner, $RunnerIPs) -ForegroundColor Cyan
Write-Host ("StageRoot: {0}" -f $StageRoot) -ForegroundColor Cyan

# Validate central access
if (-not (Test-Path $CentralResults)) { throw "CentralResults not reachable: $CentralResults" }
if (-not (Ensure-Writeable $CentralResults)) { throw "No write access to CentralResults: $CentralResults" }

# Always include local source
$LocalSourceRoot = "C:\PerfLocalStage"
New-Item -ItemType Directory -Path $LocalSourceRoot -Force | Out-Null
$Sources = @(@{ Name="LOCAL_C"; Path=$LocalSourceRoot }) + $UncSources

# Filter sources reachable + writable
$GoodSources = @()
foreach ($s in $Sources) {
  if (-not (Test-Path $s.Path)) { Write-Warning ("Skipping source not reachable from {0}: {1}" -f $Runner, $s.Path); continue }
  if (-not (Ensure-Writeable $s.Path)) { Write-Warning ("Skipping source not writable from {0}: {1}" -f $Runner, $s.Path); continue }
  $GoodSources += $s
}
if (-not $GoodSources) { throw "No valid sources available from runner." }

# Filter destinations reachable + writable
$GoodDests = @()
foreach ($d in $Destinations) {
  if (-not (Test-Path $d.Path)) { Write-Warning ("Skipping dest not reachable: {0}" -f $d.Path); continue }
  if (-not (Ensure-Writeable $d.Path)) { Write-Warning ("Skipping dest not writable: {0}" -f $d.Path); continue }
  $GoodDests += $d
}
if (-not $GoodDests) { throw "No valid destinations reachable from runner." }

# Create stage file
$fileName  = "perf_{0}GB.dat" -f $TestSizeGB
$stageFile = Join-Path $StageSrc $fileName
Write-Host ("Creating stage file: {0} ({1} GB)" -f $stageFile, $TestSizeGB) -ForegroundColor Yellow
New-TestFile -FilePath $stageFile -SizeGB $TestSizeGB

$results = @()

foreach ($src in $GoodSources) {
  $srcName = $src.Name
  $srcRoot = ($src.Path).TrimEnd('\\')
  $srcDir  = Join-Path $srcRoot ("_PERF_SRC_" + $Runner)
  New-Item -ItemType Directory -Path $srcDir -Force | Out-Null

  Write-Host ("`n[SOURCE PREP] {0} -> {1}" -f $srcName, $srcDir) -ForegroundColor Cyan
  $prep = Invoke-RobocopyTimed -SourceDir $StageSrc -DestDir $srcDir -FileName $fileName -Tag ("prep_" + $srcName)
  if (-not $prep.Success) {
    Write-Warning ("Prep failed for {0} (ExitCode={1}). Skipping." -f $srcName, $prep.ExitCode)
    try { Remove-Item $srcDir -Force -Recurse -ErrorAction SilentlyContinue } catch {}
    continue
  }

  foreach ($dst in $GoodDests) {
    $dstName = $dst.Name
    $dstRoot = ($dst.Path).TrimEnd('\\')
    $dstDir  = Join-Path $dstRoot ("_PERFTEST_" + $Runner)
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null

    $writeTimes = @()
    $readTimes  = @()
    $logs = @($prep.LogPath)

    for ($i=1; $i -le $Iterations; $i++) {
      Write-Host ("`n=== [{0}] [{1} -> {2}] WRITE {3}/{4} ===" -f $Runner, $srcName, $dstName, $i, $Iterations) -ForegroundColor Green
      $w = Invoke-RobocopyTimed -SourceDir $srcDir -DestDir $dstDir -FileName $fileName -Tag ("w_{0}_{1}_{2}" -f $srcName,$dstName,$i)
      $logs += $w.LogPath
      if ($w.Success) { $writeTimes += $w.Seconds } else { Write-Warning ("WRITE failed (ExitCode={0})" -f $w.ExitCode) }

      Write-Host ("`n=== [{0}] [{1} -> {2}] READ  {3}/{4} (dest->stage_out) ===" -f $Runner, $srcName, $dstName, $i, $Iterations) -ForegroundColor Green
      $outFile = Join-Path $StageOut $fileName
      if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
      $r = Invoke-RobocopyTimed -SourceDir $dstDir -DestDir $StageOut -FileName $fileName -Tag ("r_{0}_{1}_{2}" -f $srcName,$dstName,$i)
      $logs += $r.LogPath
      if ($r.Success) { $readTimes += $r.Seconds } else { Write-Warning ("READ failed (ExitCode={0})" -f $r.ExitCode) }

      try { Remove-Item (Join-Path $dstDir $fileName) -Force -ErrorAction SilentlyContinue } catch {}
      try { Remove-Item (Join-Path $StageOut $fileName) -Force -ErrorAction SilentlyContinue } catch {}
    }

    $avgW = if ($writeTimes.Count) { ($writeTimes | Measure-Object -Average).Average } else { $null }
    $avgR = if ($readTimes.Count)  { ($readTimes  | Measure-Object -Average).Average } else { $null }
    $wMB  = if ($avgW) { [math]::Round((($TestSizeGB*1024)/$avgW), 2) } else { $null }
    $rMB  = if ($avgR) { [math]::Round((($TestSizeGB*1024)/$avgR), 2) } else { $null }

    $srcSrv = Get-UncServer $src.Path
    $dstSrv = Get-UncServer $dst.Path

    $results += [PSCustomObject]@{
      RunnerHost=$Runner
      RunnerIPv4=$RunnerIPs
      Timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
      SourceName=$srcName
      SourceUNC=$src.Path
      SourceServer=$srcSrv
      SourceIPv4=((Resolve-IPv4 $srcSrv) -join ", ")
      DestName=$dstName
      DestUNC=$dst.Path
      DestServer=$dstSrv
      DestIPv4=((Resolve-IPv4 $dstSrv) -join ", ")
      TestSizeGB=$TestSizeGB
      Iterations=$Iterations
      AvgWrite_s= if ($avgW) { [math]::Round($avgW,2) } else { $null }
      Write_MBps=$wMB
      AvgRead_s=  if ($avgR) { [math]::Round($avgR,2) } else { $null }
      Read_MBps=$rMB
      RoboLogs=($logs -join "; ")
    }

    if ($CleanupTemp) { try { Remove-Item $dstDir -Force -Recurse -ErrorAction SilentlyContinue } catch {} }
  }

  if ($CleanupTemp) { try { Remove-Item $srcDir -Force -Recurse -ErrorAction SilentlyContinue } catch {} }
}

$csv = Join-Path $CentralResults ("Perf_{0}_{1}.csv" -f $Runner, (Get-Date -Format "yyyyMMdd_HHmmss"))
$results | Export-Csv -NoTypeInformation -Path $csv
Write-Host ("`nSaved CSV: {0}" -f $csv) -ForegroundColor Yellow

if ($CleanupTemp) {
  try { Remove-Item $stageFile -Force -ErrorAction SilentlyContinue } catch {}
  try { Remove-Item $StageRoot -Force -Recurse -ErrorAction SilentlyContinue } catch {}
}

Write-Host ("DONE (runner {0})" -f $Runner) -ForegroundColor Green
