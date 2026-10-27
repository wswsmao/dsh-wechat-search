# Pure parsing/export helpers; no desktop access in this module.
function Normalize-Text([string]$Text) { return [regex]::Replace($Text,'\s+',' ').Trim() }
function ConvertTo-PublicArticleUrl([string]$Value) {
    $uri=[uri]$Value
    if($uri.Scheme -notin @('http','https') -or $uri.Host -ne 'mp.weixin.qq.com'){ throw 'ARTICLE_URL_HOST' }
    if($uri.AbsolutePath -cmatch '^/s/[A-Za-z0-9_-]{22}$'){ return 'https://mp.weixin.qq.com'+$uri.AbsolutePath }
    $allowed=@('__biz','mid','idx','sn');$parts=@{}
    foreach($part in $uri.Query.TrimStart('?').Split('&')) {
        $pair=$part.Split('=',2)
        if($pair.Count -eq 2 -and $pair[0] -in $allowed){ $parts[$pair[0]]=[uri]::UnescapeDataString($pair[1]) }
    }
    if($parts.Count -ne 4 -or $parts.mid -notmatch '^\d+$' -or $parts.idx -notmatch '^\d+$' -or $parts.sn -notmatch '^[a-fA-F0-9]{32}$' -or $parts.__biz -notmatch '^[A-Za-z0-9+/=]+$'){throw 'ARTICLE_ID_NOT_READY'}
    return 'https://mp.weixin.qq.com/s?'+(($allowed|ForEach-Object{$_+'='+[uri]::EscapeDataString($parts[$_])}) -join '&')
}
function Get-ArticleIdentity([string]$Url) {
    $u=[uri]$Url
    if($u.AbsolutePath -cmatch '^/s/[A-Za-z0-9_-]{22}$'){return 'short:'+($u.AbsolutePath.Substring(3))}
    $q=@{};foreach($p in $u.Query.TrimStart('?').Split('&')){$s=$p.Split('=',2);if($s.Count -eq 2){$q[$s[0]]=[uri]::UnescapeDataString($s[1])}}
    return 'article:'+ $q.__biz + ':' + $q.mid + ':' + $q.idx
}
function Get-DateLabelAge([string]$Label,[datetimeoffset]$At) {
    if($Label -eq '刚刚'){return 0}
    if($Label -match '^(\d+)(分钟|小时|天|周|个月|年)前$') {return [int64]$Matches[1]*@{'分钟'=60;'小时'=3600;'天'=86400;'周'=604800;'个月'=2592000;'年'=31536000}[$Matches[2]]}
    if($Label -match '^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$') { $dt=[datetime]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3]);return ($At-[datetimeoffset]::new($dt,$At.Offset)).TotalSeconds }
    return $null
}
function ConvertFrom-SearchText([string]$Text,[string[]]$Titles,[datetimeoffset]$At) {
    $lines=$Text -split '\r?\n';$positions=@();$cursor=0
    foreach($title in $Titles){$pos=-1;for($i=$cursor;$i -lt $lines.Count;$i++){if((Normalize-Text $lines[$i]) -eq (Normalize-Text $title)){$pos=$i;break}};if($pos -lt 0){throw 'SEARCH_TEXT_TITLE_MISMATCH'};$positions+=$pos;$cursor=$pos+1}
    $items=@()
    for($i=0;$i -lt $Titles.Count;$i++){
        $end=if($i+1 -lt $positions.Count){$positions[$i+1]}else{$lines.Count};$label='';$account=''
        for($j=$positions[$i]+1;$j -lt $end;$j++){ $line=$lines[$j].Trim();if($line -match '^(刚刚|\d+(分钟|小时|天|周|个月|年)前|\d{4}[-/]\d{1,2}[-/]\d{1,2})$'){$label=$line;$account=$lines[$j-1].Trim();break} }
        if(!$label -or !$account){throw 'SEARCH_TEXT_DATE_MISSING'}
        # Keep the preview snippet the result list shows. It sits between the title and the account line
        # and lets the caller pre-screen candidates before paying to open every article.
        $snippetEnd=$positions[$i]+1
        for($j=$positions[$i]+1;$j -lt $end;$j++){ if((Normalize-Text $lines[$j].Trim()) -eq (Normalize-Text $account)){$snippetEnd=$j;break} }
        $snippet=''
        if($snippetEnd -gt $positions[$i]+1){$snippet=(($lines[($positions[$i]+1)..($snippetEnd-1)] | ForEach-Object {$_.Trim()}) -join ' ').Trim()}
        if($snippet.Length -gt 400){$snippet=$snippet.Substring(0,400)}
        $items+=@{title=$Titles[$i];account=$account;relative_date=$label;age_seconds=(Get-DateLabelAge $label $At);age_reference=$At.ToString('o');index=$i;snippet=$snippet}
    }
    return ,$items
}
function Get-WindowMembership($Record,[datetimeoffset]$Cutoff,[datetimeoffset]$Reference) {
    if($Record.published_at_iso){$d=[datetimeoffset]::Parse($Record.published_at_iso);return ($d -ge $Cutoff -and $d -le $Reference)}
    $d=[datetimeoffset]::new([datetime]::ParseExact($Record.date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture),[timespan]::FromHours(8));$end=$d.AddDays(1)
    if($d -ge $Cutoff -and $end -le $Reference){return $true}
    if($end -le $Cutoff -or $d -gt $Reference){return $false}
    return $null
}
function Write-AtomicJson([string]$Path,$Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 30
    $temp=$Path+'.tmp';[IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,$Path+'.bak')}else{[IO.File]::Move($temp,$Path)}
}
function ConvertTo-SafeCsvCell($Value) {
    $s=[string]$Value
    if($s -match '^\s*[=+@\-]'){ $s="'"+$s }
    return '"'+$s.Replace('"','""')+'"'
}
function Write-ResultCsv([string]$Path,$Records) {
    $fields=@('title','url','author','account','date','published_at_iso','publication_precision','content_type')
    $rows=[Collections.Generic.List[string]]::new();$rows.Add(($fields -join ','))
    foreach($r in $Records){$rows.Add((($fields|ForEach-Object{ConvertTo-SafeCsvCell $r[$_]}) -join ','))}
    $temp=$Path+'.tmp';[IO.File]::WriteAllText($temp,($rows -join "`r`n")+"`r`n",[Text.UTF8Encoding]::new($true))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,$Path+'.bak')}else{[IO.File]::Move($temp,$Path)}
}
