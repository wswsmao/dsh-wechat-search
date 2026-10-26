$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'collector\Core.ps1')
$current=@(@{title='same';account='a';index=0})
$old=@(@{title='same';account='a';index=0},@{title='same';account='a';index=1},@{title='missing';account='b';index=2})
$counts=@{};foreach($c in $current){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);if(!$counts.ContainsKey($k)){$counts[$k]=0};$counts[$k]++}
$occ=@{};foreach($c in $old){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);if(!$occ.ContainsKey($k)){$occ[$k]=0};$occ[$k]++;if(!$counts.ContainsKey($k) -or $occ[$k] -gt $counts[$k]){$current+=@{title=$c.title;account=$c.account;index=-1}}}
if($current.Count -ne 3 -or @($current|Where-Object{$_.index -lt 0}).Count -ne 2){throw 'Resume multiset candidate retention regression'}
$ref=[datetimeoffset]::Parse('2026-10-20T12:00:00+08:00');$cut=$ref.AddDays(-3);$now=$ref.AddDays(2);$threshold=($now-$cut).TotalSeconds+86400
if($threshold -ne 6*86400){throw 'Delayed resume boundary regression'}
Write-Output 'PASS: resume candidate multiset retention, negative-index refusal contract and delayed fixed-window boundary'
