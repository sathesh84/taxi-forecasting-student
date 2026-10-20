<#
.SYNOPSIS
    Golden path: run the whole project end to end from a clean checkout.

.DESCRIPTION
    Executes every local stage in order and stops at the first failure:
    1. Quality gate        (ruff + pytest, same checks as CodeBuild)
    2. Data pipeline       (download/clean/aggregate/features/splits)
    3. Model training      (XGBoost vs LightGBM, MLflow tracking + registration)
    4. Batch inference     (recursive demand forecast appended to predictions.db)
    5. Responsible AI      (subgroup metrics, SHAP plots, model cards)
    6. Drift detection     (synthetic drift report for both models)
    7. Real-time serving   (start the API locally and run the smoke-test suite)

    Every run writes a full log and a JSON summary (commit, stage status and
    duration) under artifacts/logs/ as traceable evidence.

.EXAMPLE
    .\scripts\run_all.ps1
    .\scripts\run_all.ps1 -SkipDownload -SkipTraining   # reuse data and registered models
#>

[CmdletBinding()]
param(
    [int]$Year = 2024,
    [int]$Month = 1,
    # Optuna trials per estimator. Omit to use the configured default.
    [int]$NTrials = 1,
    # Batch forecast horizon in hours.
    [int]$Horizon = 3,
    # Reuse cached raw data (only valid after one successful download).
    [switch]$SkipDownload,
    # Reuse already registered models instead of retraining.
    [switch]$SkipTraining,
    [int]$ApiPort = 8000
)

$ErrorActionPreference = "Continue"

# Repo root = parent of this script's directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    Write-Host "Missing .venv - create it first (see docs/SETUP.md)." -ForegroundColor Red
    exit 1
}

$env:PYTHONUNBUFFERED = "1"
$env:PYTHONIOENCODING = "utf-8"

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir = Join-Path $RepoRoot "artifacts\logs"
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogFile = Join-Path $LogDir "golden_path_$Stamp.log"
$SummaryFile = Join-Path $LogDir "golden_path_$Stamp.json"
$Commit = (git rev-parse --short HEAD).Trim()

$results = @()
# Windows PowerShell 5.1 writes UTF-16 from Tee-Object/Add-Content; append UTF-8
# explicitly so the log stays a single readable encoding.
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Add-LogLine([string]$Text) {
    [System.IO.File]::AppendAllText($LogFile, "$Text`r`n", $Utf8)
}

function Write-Log([string]$Text, [string]$Color = "Gray") {
    Write-Host $Text -ForegroundColor $Color
    Add-LogLine $Text
}

function Save-Summary([string]$Status) {
    [ordered]@{
        commit      = $Commit
        started     = $Stamp
        finished    = (Get-Date -Format "yyyyMMdd_HHmmss")
        status      = $Status
        parameters  = [ordered]@{
            year = $Year; month = $Month; n_trials = $NTrials; horizon = $Horizon
            skip_download = [bool]$SkipDownload; skip_training = [bool]$SkipTraining
        }
        stages      = $script:results
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $SummaryFile -Encoding utf8
}

function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action)
    Write-Log ""
    Write-Log "=== $Name === $(Get-Date -Format 'HH:mm:ss')" "Cyan"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # Merge stderr (Python logging) into the stream so it reaches the log file.
    & $Action 2>&1 | ForEach-Object { $line = "$_"; Write-Host $line; Add-LogLine $line }
    $code = $LASTEXITCODE
    $timer.Stop()
    $seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
    $script:results += [ordered]@{ stage = $Name; status = $(if ($code -eq 0) { "passed" } else { "failed" }); seconds = $seconds }
    if ($code -ne 0) {
        Write-Log "FAILED: $Name (exit $code) after ${seconds}s" "Red"
        Save-Summary "failed"
        Write-Log "Log: $LogFile" "Yellow"
        exit 1
    }
    Write-Log "OK: $Name (${seconds}s)" "Green"
}

Write-Log "Golden path run $Stamp at commit $Commit" "Cyan"

Invoke-Stage "1. Quality gate - ruff" { & $Python -m ruff check . }
Invoke-Stage "1. Quality gate - pytest" { & $Python -m pytest -q -p no:cacheprovider }

$pipelineArgs = @("-m", "scripts.run_pipeline", "--year", $Year, "--month", $Month)
if ($SkipDownload) { $pipelineArgs += "--skip-download" }
Invoke-Stage "2. Data pipeline" { & $Python @pipelineArgs }

if ($SkipTraining) {
    Write-Log "`nSkipping training (-SkipTraining): using registered models." "Yellow"
}
else {
    Invoke-Stage "3. Model training + registration" {
        & $Python -m scripts.train_models --n-trials $NTrials
    }
}

Invoke-Stage "4. Batch inference" { & $Python -m scripts.batch_forecast --horizon $Horizon }
Invoke-Stage "5. Responsible AI analysis" { & $Python -m scripts.responsible.run_analysis }
Invoke-Stage "6. Drift detection" {
    & $Python -m scripts.monitoring.demo_drift_report --problem all --mode drift
}

# --- 7. Real-time serving: start the API, wait for health, run smoke tests ---
$ApiUrl = "http://127.0.0.1:$ApiPort"
$apiLog = Join-Path $LogDir "golden_path_api_$Stamp.log"
$api = Start-Process -FilePath $Python -PassThru -WindowStyle Hidden `
    -ArgumentList "-m", "uvicorn", "src.serving.api:app", "--host", "127.0.0.1", "--port", $ApiPort `
    -RedirectStandardOutput $apiLog -RedirectStandardError "$apiLog.err"
try {
    Invoke-Stage "7. Real-time serving - API readiness" {
        $deadline = (Get-Date).AddSeconds(180)
        $ready = $false
        while (-not $ready -and (Get-Date) -lt $deadline) {
            try {
                $health = Invoke-RestMethod "$ApiUrl/health" -TimeoutSec 5
                if ($health.status -eq "ok") { $ready = $true; break }
            }
            catch { }
            Start-Sleep -Seconds 3
        }
        if ($ready) {
            $health | ConvertTo-Json -Depth 4
            cmd /c "exit 0"
        }
        else {
            "API did not report status=ok within 180s (see $apiLog.err)"
            cmd /c "exit 1"
        }
    }
    Invoke-Stage "7. Real-time serving - smoke tests" {
        & $Python -m scripts.aws.verify_staging --api-url $ApiUrl --timeout 120 `
            --output (Join-Path $LogDir "golden_path_smoke_$Stamp.json")
    }
}
finally {
    if ($api -and -not $api.HasExited) { Stop-Process -Id $api.Id -Force }
}

Save-Summary "passed"
Write-Log ""
Write-Log "GOLDEN PATH PASSED - all stages completed at commit $Commit" "Green"
Write-Log "Log:     $LogFile"
Write-Log "Summary: $SummaryFile"
exit 0
