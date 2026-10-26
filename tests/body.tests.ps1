$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'collector\Core.ps1'),[Text.Encoding]::UTF8)))
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'collector\Body.ps1'),[Text.Encoding]::UTF8)))
function Assert($Value,[string]$Message){if(!$Value){throw "FAIL: $Message"}}
$r=New-BodyCapture "alpha`ncode block`nbeta" 'uia_content_range' $true 500000
Assert ($r.body_status -eq 'ok' -and $r.body_complete -and $r.body_chars -eq $r.body_text.Length) 'body plaintext completeness'
$t=New-BodyCapture ('x'*100) 'uia_content_range' $true 20
Assert ($t.body_text.Length -eq 20 -and $t.body_status -eq 'truncated' -and !$t.body_complete -and $t.body_truncated) 'body safety limit explicit'
$p=New-BodyCapture 'content only' 'anchored_page_selection' $false
Assert ($p.body_status -eq 'partial' -and !$p.body_complete) 'fallback not claimed complete'
$u=New-BodyCapture '' 'content_element_missing' $false
Assert ($u.body_status -eq 'unavailable' -and $u.body_chars -eq 0 -and !$u.body_complete) 'unavailable body explicit'
$url='https://mp.weixin.qq.com/s?__biz=MzYzNTIxNzIwNA==&mid=123&idx=1&sn=0123456789abcdef0123456789abcdef&key=SECRET&uin=PRIVATE&pass_ticket=SECRET'
$s=New-BodyCapture ("before "+$url+" after") 'uia_content_range' $true
Assert ($s.body_text -notmatch 'SECRET|PRIVATE|key=|uin=|pass_ticket=') 'body links never retain navigation secrets'
$r.body_text='private正文';$r.body_chars=$r.body_text.Length
$record=@{title='title';url='https://mp.weixin.qq.com/s/fxT7NxktgU8PMeHXY28ftQ';account='acct';date='2026-10-25'};Copy-BodyFields $record $r
$public=Get-PublicRecord $record
Assert (!$public.ContainsKey('body_text') -and !$public.ContainsKey('body_status')) 'body absent public preview'
$runtime=Join-Path $root '.runtime\tests\body-unit';[void][IO.Directory]::CreateDirectory($runtime)
Save-BodyCache 'article:public:123:1' $runtime $r
$c=Get-BodyCache 'article:public:123:1' $runtime
Assert ($c.body_text -eq 'private正文' -and $c.body_complete -and $c.body_from_cache) 'private identity cache'
Assert ($null -eq (Get-BodyCache 'article:other:123:1' $runtime)) 'cache identity isolation'
Write-ResultCsv (Join-Path $runtime 'result.csv') @($record)
$csv=Get-Content -LiteralPath (Join-Path $runtime 'result.csv') -Raw -Encoding UTF8
Assert ($csv -notmatch 'private正文|body_text') 'body not exported in CSV'
# Mock desktop reader dispatch; no real window/keyboard/clipboard calls.
function Check-Stop{}
function Body-Element($Window){return @{marker='body content'}}
function Body-TextRange($Window,$Element){return 'article only, no comments'}
$m=Read-ArticleBody @{}
Assert ($m.body_text -eq 'article only, no comments' -and $m.body_read_method -eq 'uia_content_range') 'mocked article content range'
function Body-TextRange($Window,$Element){throw 'Pattern unavailable'}
function Body-DescendantText($Element){return 'share only'}
$m=Read-ArticleBody @{}
Assert ($m.body_text -eq 'share only' -and $m.body_read_method -eq 'uia_content_descendants') 'mocked share descendants'
function Body-DescendantText($Element){return ''}
function Body-SelectionFallback($Window,$Element){return 'fallback only'}
$m=Read-ArticleBody @{}
Assert ($m.body_text -eq 'fallback only' -and !$m.body_complete -and $m.body_status -eq 'partial') 'mocked anchored fallback explicit'
function Body-Element($Window){return $null}
$m=Read-ArticleBody @{}
Assert ($m.body_status -eq 'unavailable') 'missing element not fabricated'
Write-Output 'PASS: body scope, truncation, unavailable, URL redaction, private cache, preview/CSV privacy and mocked extraction'
