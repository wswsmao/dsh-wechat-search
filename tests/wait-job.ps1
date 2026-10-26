param([string]$Id,[int]$TimeoutSeconds=1200)
$ErrorActionPreference='Stop'
if($Id -notmatch '^[0-9a-f-]{36}$'){throw 'Invalid test job ID'}
$root=Split-Path $PSScriptRoot -Parent;$p=Join-Path $root ".runtime\jobs\$Id\status.json";$end=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
while([datetime]::UtcNow -lt $end){$s=Get-Content -LiteralPath $p -Encoding UTF8 -Raw|ConvertFrom-Json;if($s.status -notin @('starting','running','cancelling')){$s|Select-Object id,keyword,lookback_days,status,phase,counts,stop_reason,coverage|ConvertTo-Json -Depth 5;exit};Start-Sleep -Seconds 3}
throw 'Test observation timeout; worker still runs, do not start duplicate'
