# Daily finance news report generator.
# Triggered by Windows Task Scheduler (daily 07:00 + at logon).
# Idempotent: skips if today's report already exists.
$ErrorActionPreference = "Continue"

$dir        = $PSScriptRoot
$today      = (Get-Date).ToString("yyyy-MM-dd")
$report     = Join-Path $dir "$today.md"
$promptFile = Join-Path $dir "prompt.txt"
$logFile    = Join-Path $dir "run-daily-report.log"
# claude's stdout goes to its own file and is merged into the main log only after
# the run ends. The old code piped it straight into $logFile via Out-File, which
# holds the main log open for the whole 1-2h claude run; any overlapping trigger's
# Add-Content then failed, and $ErrorActionPreference = "Continue" swallowed the
# error, so a stolen run left no trace in the log at all. Keep the main log free.
$outFile    = Join-Path $dir "claude-output.log"
$stderrFile = Join-Path $dir "claude-stderr.log"
# Side channel for messages the main log could not accept. Nothing else ever holds
# this open, so it stays writable even while $logFile is busy.
$errFile    = Join-Path $dir "runner-errors.log"

function Log([string]$m) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path $logFile -Value "[$ts] $m" -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Do NOT fail silently: a swallowed log line is exactly what made the
        # 2026-09-30 gap undiagnosable from the log alone.
        try {
            Add-Content -Path $errFile -Value "[$ts] [log-fallback] $m || main log unavailable: $($_.Exception.Message)" -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }
}

# Heartbeat: written before every conditional below, so any invocation - one that
# exits in the guard window, loses the lock race, or dies mid-run - leaves at
# least this line behind. If a day is missing, look here first: no heartbeat
# means the task never started; a heartbeat means it started and stopped early.
Log "=== run invoked (pid $PID) ==="

# Move whatever the child process wrote to $outFile into the main log, then clear
# it. Only ever called once the child has exited, so the main log stays free for
# the whole run.
function Merge-Output {
    if (-not (Test-Path $outFile)) { return }
    try {
        $out = Get-Content -Path $outFile -Raw -Encoding UTF8
        if ($out) {
            Add-Content -Path $logFile -Value $out -Encoding UTF8 -ErrorAction Stop
        }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    } catch {
        Log "WARN: could not merge $outFile into the main log: $($_.Exception.Message)"
    }
}

# Publish the report so the phone sees it. Best-effort by design: the report is
# already on disk by the time this runs, so a push failure must never fail the
# task or lose the day's work. The task fires every 2h, so any failure here is
# retried on the next firing through the already-exists path below.
function Publish-Report {
    if (-not (Test-Path (Join-Path $dir ".git"))) {
        Log "publish: $dir is not a git repo. skip."
        return
    }
    try {
        & git -C $dir add -A 2>&1 | Out-Null
        # Exit 0 means the staged tree matches HEAD, i.e. already published.
        & git -C $dir diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Log "publish: nothing new to publish."
            return
        }
        & git -C $dir commit -q -m "report: $today" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "publish: commit failed (exit $LASTEXITCODE)."
            return
        }
        # github.com is reachable only through the local proxy, which is pinned in
        # this repo's git config. credential.interactive=false stops git from
        # opening a credential prompt that the hidden task window cannot display -
        # that would hang until the 2h execution limit kills the run.
        & git -C $dir -c credential.interactive=false push -q origin main 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Log "publish: pushed to GitHub."
        } else {
            Log "publish: push failed (exit $LASTEXITCODE). kept locally; retry next firing."
        }
    } catch {
        Log "publish: ERROR $($_.Exception.Message)"
    }
}

# 0) Guard: skip between 00:00 and 07:00.
#    The report is "today's", but before 07:00 today's market news hasn't
#    happened yet (A-share opens 09:30). Generating now would write a hollow
#    report and then lock out the whole day via the idempotency check below.
#    So skip this window; the 07:00 schedule or a later logon will generate.
$hour = (Get-Date).Hour
if ($hour -lt 7) {
    Log "guard window (00:00-07:00). skip; will generate after 07:00."
    exit 0
}

# 1) Idempotency: already generated today? skip.
if (Test-Path $report) {
    Log "today's report already exists ($today.md). skip."
    # Still try to publish: an earlier firing may have produced the report but
    # failed to push it (proxy down, offline). This is the retry path.
    Publish-Report
    exit 0
}

# 2) Lock to avoid concurrent runs (07:00 + logon may overlap).
$lockFile = Join-Path $dir ".report.lock"
$lock = $null
try {
    $lock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
} catch {
    # A lock exists. A legit run never exceeds the 2h execution limit, so an
    # older lock is a leftover from a killed process; remove it and retry.
    if ((Test-Path $lockFile) -and ((Get-Item $lockFile).LastWriteTime -lt (Get-Date).AddHours(-2))) {
        Log "stale lock detected (older than 2h). removing and retrying."
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        try {
            $lock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch {
            Log "another instance is still running. skip."
            exit 0
        }
    } else {
        Log "another instance is running. skip."
        exit 0
    }
}

try {
    # 3) Locate claude.exe (survives VSCode extension version bumps).
    $claude = $null
    $extDir = Join-Path $env:USERPROFILE ".vscode\extensions"
    if (Test-Path $extDir) {
        $claude = Get-ChildItem -Path $extDir -Directory -Filter "anthropic.claude-code-*" |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { Join-Path $_.FullName "resources\native-binary\claude.exe" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
    if (-not $claude) {
        Log "claude.exe not found. abort."
        exit 1
    }
    Log "using claude.exe: $claude"

    $prompt = Get-Content -Path $promptFile -Raw -Encoding UTF8
    Set-Location $dir

    # 4) Generate the report. claude's stdout lands in its own file so the main
    #    log is never held open across the long run (see the note at the top).
    Log "start generating $today ..."
    & $claude -p $prompt --dangerously-skip-permissions 2>$stderrFile |
        Out-File -FilePath $outFile -Encoding UTF8
    Log "claude finished (exit $LASTEXITCODE)."

    # 4b) Fold that output into the main log now that nothing holds it open.
    Merge-Output

    # 5) Fallback: ensure data.js is rebuilt regardless.
    if (Test-Path $report) {
        $python = "C:\Users\jiaruo\AppData\Local\Programs\Python\Python312\python.exe"
        if (Test-Path $python) {
            & $python (Join-Path $dir "build.py") 2>&1 |
                Out-File -FilePath $outFile -Encoding UTF8
            $buildExit = $LASTEXITCODE
            Merge-Output
            Log "build.py fallback ran (exit $buildExit)."
        }
        Log "done. report ready."
        # 6) Publish so the phone sees today's report without a manual push.
        Publish-Report
    } else {
        Log "WARN: $today.md was not created. generation may have failed."
    }
} finally {
    if ($lock) { $lock.Close() }
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
exit 0
