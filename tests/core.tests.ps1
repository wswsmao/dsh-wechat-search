$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'collector\Core.ps1')
function Assert($Condition,[string]$Message){if(!$Condition){throw "FAIL: $Message"}}
$reference=[datetimeoffset]::Parse('2026-10-26T12:00:00+08:00');$cutoff=$reference.AddDays(-1)
$safe=ConvertTo-PublicArticleUrl 'https://mp.weixin.qq.com/s/index.html?__biz=MzYzNTIxNzIwNA==&mid=123&idx=1&sn=0123456789abcdef0123456789abcdef&key=SECRET&uin=SECRET&pass_ticket=SECRET'
Assert ($safe -notmatch 'SECRET|index.html|pass_ticket|uin=|key=') 'public URL drops secrets and wrapper'
Assert ((Get-ArticleIdentity $safe) -eq 'article:MzYzNTIxNzIwNA==:123:1') 'article identity'
Assert ((ConvertTo-PublicArticleUrl 'https://mp.weixin.qq.com/s/fxT7NxktgU8PMeHXY28ftQ?key=SECRET') -eq 'https://mp.weixin.qq.com/s/fxT7NxktgU8PMeHXY28ftQ') 'short URL'
$thrown=$false;try{ConvertTo-PublicArticleUrl 'https://evil.test/s?a=1'|Out-Null}catch{$thrown=$true};Assert $thrown 'host restricted'
Assert (Get-WindowMembership @{published_at_iso='2026-10-25T12:00:00+08:00'} $cutoff $reference) 'inclusive lower endpoint'
Assert (!(Get-WindowMembership @{published_at_iso='2026-10-25T11:59:00+08:00'} $cutoff $reference)) 'outside one minute'
Assert ($null -eq (Get-WindowMembership @{date='2026-10-25';published_at_iso=$null} $cutoff $reference)) 'date-only boundary uncertain'
Assert ((Get-WindowMembership @{date='2026-10-24';published_at_iso=$null} $cutoff $reference) -eq $false) 'outside date-only'
Assert ((Get-WindowMembership @{date='2026-10-25';published_at_iso=$null} $reference.AddDays(-3) $reference) -eq $true) 'whole day within window'
$text="`nkeyword`nsame title`nsnippet 1`naccount A`n1小时前`nsame title`nsnippet 2`naccount B`n2天前`n"
$parsed=ConvertFrom-SearchText $text @('same title','same title') $reference
Assert ($parsed.Count -eq 2 -and $parsed[0].account -eq 'account A' -and $parsed[1].account -eq 'account B') 'duplicate titles kept by cursor'
Assert ($parsed[1].age_seconds -eq 172800) 'relative date parser'
Assert ((ConvertTo-SafeCsvCell '=HYPERLINK("evil")') -like '*''=*') 'spreadsheet formula injection escaped'
$testDir=Join-Path (Split-Path $PSScriptRoot -Parent) '.runtime\tests\core';[void][IO.Directory]::CreateDirectory($testDir)
Write-AtomicJson (Join-Path $testDir 'test.json') @{items=@();value='一'};Write-AtomicJson (Join-Path $testDir 'test.json') @{items=@(1,2);value='二'}
$read=Get-Content (Join-Path $testDir 'test.json') -Encoding UTF8 -Raw|ConvertFrom-Json;Assert ($read.items.Count -eq 2 -and $read.value -eq '二') 'atomic UTF8 replacement'
Write-ResultCsv (Join-Path $testDir 'test.csv') @(@{title='带,逗号';url=$safe;author='';account='测试';date='2026-10-25'})
$rows=Import-Csv (Join-Path $testDir 'test.csv') -Encoding UTF8;Assert ($rows.title -eq '带,逗号') 'CSV round trip'
Write-Output 'PASS: pure PowerShell parsing, URL sanitization, time windows, duplicate titles, CSV and atomic state'
