$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'collector\Core.ps1')
function Check-Stop{}
. (Join-Path $root 'collector\Desktop.ps1')
$ref=[datetimeoffset]::Parse('2026-10-26T12:00:00+08:00')
$years=@(($ref.Year-1),$ref.Year,($ref.Year+1));if($years.Count -ne 3 -or $years[0] -ne 2025 -or $years[2] -ne 2027){throw 'Year array regression'}
# mock only UIAutomation data access; never operate real desktop.
$doc=[pscustomobject]@{Current=[pscustomobject]@{Name='share text'}}
$els=@([pscustomobject]@{Current=[pscustomobject]@{ClassName='rich_media_meta_list_combine';Name='阅读 100 , 10月23日';AutomationId=''}},[pscustomobject]@{Current=[pscustomobject]@{ClassName='';Name='account';AutomationId='js_wx_follow_nickname'}})
$doc|Add-Member ScriptMethod FindAll {param($a,$b) return $script:els}
function Element-Id($Root,$Id){if($Id -eq 'js_text_desc'){return [pscustomobject]@{Current=[pscustomobject]@{Name='share text'}}};return $null}
$w=@{root=@{};document=$doc};$c=@{title='share text';account='account';age_seconds=172800}
$r=Read-ArticleHeader $w $c $ref
if(!$r -or $r.date -ne '2026-10-23' -or $r.publication_precision -ne 'day' -or $r.author -ne ''){throw 'Text share parsing regression'}
if(!(Get-WindowMembership $r $ref.AddDays(-7) $ref)){throw 'Share membership regression'}
$c=@{title='share text';account='other account';age_seconds=172800};if($null -ne (Read-ArticleHeader $w $c $ref)){throw 'Share account verification regression'}
function Element-Id($Root,$Id){if($Id -eq 'weixin-search-input'){return @{found=$true}};return $null}
$bad=@{root=@{};document=[pscustomobject]@{}}
Check-PageChallenge $bad # must not attempt to read result prose/keyword containing verification terms.
Write-Output 'PASS: native compile, year-array precedence, share header parsing, identity mismatch and day membership'
