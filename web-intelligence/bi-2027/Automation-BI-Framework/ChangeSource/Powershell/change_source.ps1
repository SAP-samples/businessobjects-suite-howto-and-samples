# ============================================================================
#  change_source.ps1 - Bulk/Single Webi "Change Source" WITHOUT Bruno
# ----------------------------------------------------------------------------
#  Mirrors the Bruno "00 - Bulk Change Source (All-in-One)" flow:
#    logon -> per doc: open -> list dataproviders -> compute mapping
#             (04a default GET / 04a2 GET+strategies) -> apply (04b POST)
#             -> save (empty PUT) -> close -> logoff.
#
#  Config is READ FROM environments/my-env.bru (same single source of truth
#  Bruno uses). Zero install: PowerShell ships with Windows.
#
#  USAGE (from the WebiChangeSource folder):
#     powershell -ExecutionPolicy Bypass -File .\change_source.ps1
#     # optional per-run overrides:
#     .\change_source.ps1 -DocIds "5418,5403" -StrategyMode custom -Test
# ============================================================================
[CmdletBinding()]
param(
  [string]$EnvFile,         # path to my-env.bru (default resolved below)
  [string]$DocIds,          # override docIds (comma separated)
  [string]$TargetUniverse,  # override targetuniverse
  [ValidateSet("default","custom")] [string]$StrategyMode, # override strategyMode
  [switch]$Test,            # force dry run (runnerAction=test)
  [switch]$NoPause          # do not wait for Enter at the end
)

$ErrorActionPreference = "Stop"

# Resolve the script's own folder robustly ($PSScriptRoot can be empty in some
# launch contexts). Fall back to $MyInvocation, then the current directory.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

# Default env file = <scriptDir>\environments\my-env.bru unless -EnvFile given.
if (-not $EnvFile) { $EnvFile = Join-Path $scriptDir "environments\my-env.bru" }
$ProgressPreference = "SilentlyContinue"   # hide Invoke-WebRequest progress bar for clean logs
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {}

# ---------------- parse my-env.bru (vars { key: value }) ----------------
function Read-BruVars([string]$path) {
  if (-not (Test-Path $path)) { throw "Env file not found: $path" }
  $vars = @{}
  $inVars = $false
  foreach ($raw in Get-Content -LiteralPath $path) {
    $line = $raw.Trim()
    if ($line -match '^vars\s*\{') { $inVars = $true; continue }
    if ($inVars -and $line -eq '}') { break }
    if ($inVars -and $line -and ($line -notmatch '^//')) {
      $idx = $line.IndexOf(':')
      if ($idx -gt 0) {
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $vars[$key] = $val
      }
    }
  }
  return $vars
}

$cfg = Read-BruVars $EnvFile

# ---------------- resolve config (CLI overrides env file) ----------------
$baseUrl  = ($cfg['baseUrl']).TrimEnd('/')
$cms      = $cfg['cms']
$user     = $cfg['user']
$password = $cfg['password']
$auth     = $cfg['auth']
$target   = if ($TargetUniverse) { $TargetUniverse } else { $cfg['targetuniverse'] }
$runnerAction = if ($Test) { "test" } elseif ($cfg['runnerAction']) { $cfg['runnerAction'] } else { "change" }
$dryRun   = ($runnerAction.ToLower() -eq "test")
$mode     = if ($StrategyMode) { $StrategyMode } elseif ($cfg['strategyMode']) { $cfg['strategyMode'] } else { "default" }
$useCustom = ($mode.ToLower() -eq "custom")
$docIdsRaw = if ($DocIds) { $DocIds } else { $cfg['docIds'] }

$REST = "$baseUrl/biprws"

# doc ids: extract every alphanumeric token (works the same in Windows
# PowerShell 5.1 and PowerShell 7, regardless of the separator byte in the
# file). Build a plain [string[]] and de-dupe preserving order.
[string[]]$docIds = @()
if ($docIdsRaw) {
  $rawStr = [string]$docIdsRaw
  # NOTE: do NOT use $matches - it is a reserved automatic variable in PowerShell.
  $mc = [System.Text.RegularExpressions.Regex]::Matches($rawStr, '[A-Za-z0-9_]+')
  $ordered = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  for ($k = 0; $k -lt $mc.Count; $k++) {
    $tok = $mc[$k].Value
    if ($tok -and $seen.Add($tok)) { $ordered.Add($tok) }
  }
  $docIds = $ordered.ToArray()
}

# strategies body (custom mode). Use mappingStrategies from env if present+valid.
function Get-Strategies($cfg) {
  $raw = $cfg['mappingStrategies']
  if ($raw) {
    try { return ($raw | ConvertFrom-Json) } catch {
      Write-Host "  [STRATEGY] invalid mappingStrategies JSON - using built-in default."
    }
  }
  return [pscustomobject]@{
    strategies = [pscustomobject]@{
      strategy = @(
        [pscustomobject]@{ name = "SamePath";          enabled = $true  },
        [pscustomobject]@{ name = "SameTechnicalName"; enabled = $true  },
        [pscustomobject]@{ name = "SameName";          enabled = $true  },
        [pscustomobject]@{ name = "Removal";           enabled = $false }
      )
    }
  }
}
$STRATEGIES = if ($useCustom) { Get-Strategies $cfg } else { $null }

# ---------------- HTTP helper ----------------
$script:token = $null
function Invoke-Api {
  param(
    [string]$Method,
    [string]$Path,
    $Body = $null
  )
  $headers = @{ "Accept" = "application/json" }
  if ($script:token) { $headers["X-SAP-LogonToken"] = $script:token }
  $uri = "$REST$Path"
  try {
    if ($null -ne $Body) {
      $json = $Body | ConvertTo-Json -Depth 40 -Compress
      $resp = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers `
                -ContentType "application/json" -Body $json -UseBasicParsing
    } else {
      $resp = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers `
                -ContentType "application/json" -UseBasicParsing
    }
    return [pscustomobject]@{ ok = $true; status = [int]$resp.StatusCode; headers = $resp.Headers; body = $resp.Content }
  } catch {
    $status = 0; $bodyTxt = $_.Exception.Message
    if ($_.Exception.Response) {
      try {
        $status = [int]$_.Exception.Response.StatusCode.value__
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        try { $bodyTxt = $sr.ReadToEnd() } finally { $sr.Close() }
      } catch {}
    }
    return [pscustomobject]@{ ok = $false; status = $status; headers = $null; body = $bodyTxt }
  }
}

# Send a raw JSON string body (used to re-post the exact mapping payload)
function Invoke-ApiRaw {
  param([string]$Method, [string]$Path, [string]$JsonBody)
  $headers = @{ "Accept" = "application/json" }
  if ($script:token) { $headers["X-SAP-LogonToken"] = $script:token }
  $uri = "$REST$Path"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers `
              -ContentType "application/json" -Body $JsonBody -UseBasicParsing
    return [pscustomobject]@{ ok = $true; status = [int]$resp.StatusCode; body = $resp.Content }
  } catch {
    $status = 0; $bodyTxt = $_.Exception.Message
    if ($_.Exception.Response) {
      try {
        $status = [int]$_.Exception.Response.StatusCode.value__
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        try { $bodyTxt = $sr.ReadToEnd() } finally { $sr.Close() }
      } catch {}
    }
    return [pscustomobject]@{ ok = $false; status = $status; body = $bodyTxt }
  }
}

function As-Array($x) {
  if ($null -eq $x) { return @() }
  if ($x -is [System.Array]) { return $x }
  return @($x)
}

function Close-Doc([string]$docId) {
  $close = Invoke-Api -Method PUT -Path "/raylight/v1/documents/$docId/occurrences/0" `
             -Body (@{ occurrence = @{ state = @{ '$' = "Unused" } } })
  Write-Host ("  [CLOSE] occurrences/0 -> Unused (status {0})" -f $close.status)
}

# ---------------- MAIN ----------------
$line = ("=" * 60)
Write-Host $line
Write-Host ("BULK CHANGE SOURCE (PowerShell)  |  mode = {0}  |  target universe = {1}" -f $(if ($dryRun) {"DRY RUN (test)"} else {"CHANGE"}), $target)
Write-Host ("Strategy: {0}" -f $(if ($useCustom) {"CUSTOM (declared strategies)"} else {"DEFAULT (regular mapping)"}))
Write-Host ("REST root: {0}" -f $REST)
Write-Host ("Config file: {0}" -f $EnvFile)
Write-Host ("Documents to process: {0}  (count={1})" -f ($docIds -join ", "), $docIds.Count)
Write-Host $line

if ($docIds.Count -eq 0) { Write-Host "ABORT: docIds is empty (my-env.bru or -DocIds)."; exit 1 }
if (-not $target)        { Write-Host "ABORT: targetuniverse is empty."; exit 1 }

# Logon
$logon = Invoke-Api -Method POST -Path "/logon/long" -Body (@{ userName = $user; password = $password; auth = $auth; cms = $cms })
if (-not $logon.ok) { Write-Host "ABORT: logon failed status=$($logon.status) (response body omitted for security)"; exit 1 }
$script:token = $null
if ($logon.headers -and $logon.headers["X-SAP-LogonToken"]) { $script:token = [string]$logon.headers["X-SAP-LogonToken"] }
if (-not $script:token) { try { $script:token = ($logon.body | ConvertFrom-Json).logonToken } catch {} }
if ($script:token) { $script:token = $script:token.Trim([char]34) }
if (-not $script:token) {
  Write-Host "ABORT: no logon token returned."
  # Logon call succeeded (HTTP 2xx) but no token in response - logoff to clean up the server session.
  Invoke-Api -Method POST -Path "/logoff" | Out-Null
  exit 1
}
Write-Host "[LOGON] ok"

$summary = New-Object System.Collections.ArrayList

try {
  foreach ($docId in $docIds) {
  Write-Host ""
  Write-Host ("---- DOC {0} ----" -f $docId)
  $r = [ordered]@{ docId = $docId; status = "OK"; queries = 0; changed = 0; skipped = 0; failed = 0 }

  # Open
  $open = Invoke-Api -Method GET -Path "/raylight/v1/documents/$docId"
  if (-not $open.ok) {
    if ($open.status -eq 404) {
      Write-Host "  [OPEN] NOT FOUND - docId $docId does not exist (HTTP 404). Check docIds in my-env.bru."
      $r.status = "NOT_FOUND"
    } elseif ($open.status -eq 401 -or $open.status -eq 403) {
      Write-Host "  [OPEN] NOT AUTHORIZED for docId $docId (HTTP $($open.status))."
      $r.status = "NOT_AUTHORIZED"
    } else {
      Write-Host "  [OPEN] FAILED for docId $docId status=$($open.status) :: $($open.body)"
      $r.status = "OPEN_FAILED"
      # The server may have partially opened the document session; close it to
      # avoid leaking an open occurrence (mirrors the Bruno JS finally block).
      Close-Doc $docId
    }
    [void]$summary.Add([pscustomobject]$r)
    continue
  }
  $docName = $docId
  try { $docName = ($open.body | ConvertFrom-Json).document.name } catch {}
  Write-Host "  [OPEN] ok - `"$docName`""

  # List data providers
  $dpResp = Invoke-Api -Method GET -Path "/raylight/v1/documents/$docId/dataproviders"
  if (-not $dpResp.ok) {
    Write-Host "  [DATAPROVIDERS] FAILED status=$($dpResp.status) :: $($dpResp.body)"
    $r.status = "DP_LIST_FAILED"
    [void]$summary.Add([pscustomobject]$r)
    Close-Doc $docId
    continue
  }
  $providers = @()
  try { $providers = @(As-Array (($dpResp.body | ConvertFrom-Json).dataproviders.dataprovider)) } catch { $providers = @() }
  $r.queries = @($providers).Count
  Write-Host ("  [DATAPROVIDERS] found {0} query(ies)" -f @($providers).Count)

  foreach ($dp in $providers) {
    $dpId   = $dp.id
    $dpName = if ($dp.name) { $dp.name } else { $dpId }
    $curSrc = if ($dp.dataSourceId) { $dp.dataSourceId } elseif ($dp.dataSource -and $dp.dataSource.id) { $dp.dataSource.id } else { "?" }

    $encDp  = [uri]::EscapeDataString([string]$dpId)
    $encTgt = [uri]::EscapeDataString([string]$target)
    $amp = [char]38   # '&' - build the query string safely
    $mapPath = "/raylight/v1/documents/$docId/dataproviders/mappings?originDataproviderIds=$encDp" + $amp + "targetDatasourceId=$encTgt" + $amp + "skipChecking=false"

    # a) COMPUTE the mapping (GET). default = plain GET (04a); custom = GET + strategies (04a2)
    $viaReq = if ($useCustom) { "04a2 (GET + strategies)" } else { "04a (plain GET)" }
    Write-Host ("    - [MAP] query `"{0}`" ({1}): computing mapping via {2} ..." -f $dpName, $dpId, $viaReq)
    $mapCompute = Invoke-Api -Method GET -Path $mapPath -Body $STRATEGIES
    $mapMode = if ($useCustom) { "custom" } else { "default" }
    if (-not $mapCompute.ok -and $useCustom) {
      Write-Host ("    - [MAP] 04a2 (GET + strategies) failed (status {0}) - falling back to 04a (plain GET)." -f $mapCompute.status)
      $mapCompute = Invoke-Api -Method GET -Path $mapPath
      $mapMode = "default(fallback)"; $viaReq = "04a (plain GET, fallback)"
    }
    if (-not $mapCompute.ok) {
      $r.failed++
      Write-Host ("    - [MAP:{0}] via {1} - query `"{2}`" ({3}): FAILED status={4} :: {5}" -f $mapMode, $viaReq, $dpName, $dpId, $mapCompute.status, $mapCompute.body)
      continue
    }

    # summarise mapping status (property name is "@status")
    $statusProp = [char]64 + "status"   # "@status" without a literal @ in source
    $mappingArr = @()
    try { $mappingArr = As-Array (($mapCompute.body | ConvertFrom-Json).mappings.content.mapping) } catch { $mappingArr = @() }
    $notOk = @($mappingArr | Where-Object {
      $prop = $_.PSObject.Properties[$statusProp]
      $prop -and (([string]$prop.Value).ToLower() -ne "ok")
    })
    Write-Host ("    - [MAP:{0}] query `"{1}`" ({2}): {3} object mapping(s), {4} not-Ok" -f $mapMode, $dpName, $dpId, $mappingArr.Count, $notOk.Count)

    if ($dryRun) {
      Write-Host ("    - [DRYRUN] query `"{0}`" ({1}): would change source {2} -> {3} (mapping computed, apply skipped)" -f $dpName, $dpId, $curSrc, $target)
      $r.skipped++
      continue
    }

    # b) APPLY: POST the exact computed mapping payload (04b)
    Write-Host ("    - [APPLY] query `"{0}`" ({1}): applying mapping via 04b (POST mapping) ..." -f $dpName, $dpId)
    $mapPost = Invoke-ApiRaw -Method POST -Path $mapPath -JsonBody $mapCompute.body
    if ($mapPost.ok) {
      $r.changed++
      Write-Host ("    - [CHANGE] query `"{0}`" ({1}): source {2} -> universe {3}  OK via 04b (status {4})" -f $dpName, $dpId, $curSrc, $target, $mapPost.status)
    } else {
      $r.failed++
      Write-Host ("    - [CHANGE] query `"{0}`" ({1}): FAILED via 04b status={2} :: {3}" -f $dpName, $dpId, $mapPost.status, $mapPost.body)
    }
  }

  # Save (empty-body PUT)
  if ($dryRun) {
    Write-Host "  [SAVE] n/a - dry run"
  } elseif ($r.changed -gt 0) {
    $save = Invoke-Api -Method PUT -Path "/raylight/v1/documents/$docId"
    if ($save.ok) {
      Write-Host ("  [SAVE] saved in place - PUT documents/{0} (status {1})" -f $docId, $save.status)
    } else {
      $r.status = "SAVE_FAILED"
      Write-Host ("  [SAVE] FAILED status={0} :: {1}" -f $save.status, $save.body)
    }
  } else {
    Write-Host "  [SAVE] nothing changed"
  }

  # Close
  Close-Doc $docId
    [void]$summary.Add([pscustomobject]$r)
  }

# ---------------- SUMMARY ----------------
Write-Host ""
Write-Host $line
Write-Host "SUMMARY"
Write-Host $line
  foreach ($s in $summary) {
    Write-Host ("  Doc {0}: status={1}, queries={2}, changed={3}, skipped={4}, failed={5}" -f $s.docId, $s.status, $s.queries, $s.changed, $s.skipped, $s.failed)
  }
  Write-Host $line
} finally {
  if ($script:token) {
    $off = Invoke-Api -Method POST -Path "/logoff"
    Write-Host ("[LOGOFF] status {0}" -f $off.status)
  }
  Write-Host "Done."
}

# Keep the window open when the script is double-clicked / launched in its own
# window, so the console logs remain visible. Skips the pause in -Test/CI or
# when NoPause is set.
if (-not $NoPause) {
  try {
    Write-Host ""
    Read-Host "Press Enter to close"
  } catch { }
}
