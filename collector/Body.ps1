# Private plaintext capture. The collector owns the open public article page and desktop lock.
$script:BodyCharLimit=500000
function New-BodyCapture([string]$Text,[string]$Method,[bool]$Scoped=$true,[int]$Limit=500000) {
    if($null -eq $Text -or !$Text.Trim()){return @{body_text='';body_status='unavailable';body_chars=0;body_complete=$false;body_truncated=$false;body_limit=$Limit;body_read_method=$Method}}
    $text=$Text.Replace([string][char]0xFFFC,'').Replace([string][char]0,'').Trim()
    # A copied link must never preserve WeChat navigation/session credentials in private exports either.
    $text=[regex]::Replace($text,'https?://mp\.weixin\.qq\.com/[^\s<>"'']+',{
        param($m)
        if($m.Value -notmatch '(?:[?&]|&amp;)(key|uin|pass_ticket|exportkey|sessionid)='){return $m.Value}
        try{return (ConvertTo-PublicArticleUrl $m.Value.Replace('&amp;','&'))}catch{return '[WeChat navigation link omitted]'}
    })
    if(!$text){return @{body_text='';body_status='unavailable';body_chars=0;body_complete=$false;body_truncated=$false;body_limit=$Limit;body_read_method=$Method}}
    $truncated=$text.Length -gt $Limit
    if($truncated){$text=$text.Substring(0,$Limit)}
    $status=if($truncated){'truncated'}elseif(!$Scoped){'partial'}else{'ok'}
    return @{body_text=$text;body_status=$status;body_chars=$text.Length;body_complete=(!$truncated -and $Scoped);body_truncated=$truncated;body_limit=$Limit;body_read_method=$Method;body_captured_at=[datetimeoffset]::Now.ToString('o');body_scope='public article content plaintext; image/audio/video text is not OCRed; inline ads may remain'}
}
function Body-Element($Window) {
    $el=Element-Id $Window.root 'js_text_desc'
    if(!$el){$el=Element-Id $Window.root 'js_content'}
    if(!$el){
        $all=$Window.document.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        foreach($item in $all){if($item.Current.ClassName -match '(^|\s)rich_media_content(\s|$)'){$el=$item;break}}
    }
    return $el
}
function Body-TextRange($Window,$Element) {
    $pattern=$null
    if($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pattern)){return $pattern.DocumentRange.GetText($script:BodyCharLimit+1)}
    if($Window.document.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pattern)){
        $range=$pattern.RangeFromChild($Element)
        if($range){return $range.GetText($script:BodyCharLimit+1)}
    }
    return $null
}
function Body-DescendantText($Element) {
    $condition=New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),([System.Windows.Automation.ControlType]::Text)
    $all=$Element.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
    $builder=[Text.StringBuilder]::new()
    foreach($child in $all){Check-Stop;$value=$child.Current.Name;if($value){[void]$builder.AppendLine($value)};if($builder.Length -gt $script:BodyCharLimit){break}}
    return $builder.ToString()
}
function Body-SelectionFallback($Window,$Element) {
    # Only use the known public article window, and never return an unscoped whole page (comments/metadata).
    $condition=New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),([System.Windows.Automation.ControlType]::Text)
    $children=@($Element.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)|Where-Object{$_.Current.Name.Trim()})
    if(!$children.Count){return $null}
    $first=$children[0].Current.Name.Trim();$last=$children[-1].Current.Name.Trim()
    if(!$first -or !$last){return $null}
    $saved=[Windows.Forms.Clipboard]::GetDataObject()
    try {
        Activate-Window $Window.handle;$r=$Window.document.Current.BoundingRectangle
        [WeChatNative]::Click([int]($r.X+20),[int]($r.Y+[math]::Min(160,$r.Height-40)))
        if(![WeChatNative]::IsForeground($Window.handle)){throw 'FOCUS_UNAVAILABLE'}
        [Windows.Forms.Clipboard]::Clear();[Windows.Forms.SendKeys]::SendWait('^a^c');Desktop-Pause 200
        if(![WeChatNative]::IsForeground($Window.handle)){throw 'FOCUS_CHANGED'}
        $page=[Windows.Forms.Clipboard]::GetText();[Windows.Forms.SendKeys]::SendWait('{ESC}')
        $start=$page.IndexOf($first,[StringComparison]::Ordinal)
        if($start -lt 0){return $null}
        $end=$page.IndexOf($last,$start,[StringComparison]::Ordinal)
        if($end -lt $start){return $null}
        return $page.Substring($start,$end-$start+$last.Length)
    } finally {if($saved){try{[Windows.Forms.Clipboard]::SetDataObject($saved,$true)}catch{}}}
}
# Body capture that NEVER touches the clipboard, so several detached windows can be read concurrently
# without corrupting one another. Used by the parallel pipeline.
function Read-ArticleBody-UiaOnly($Window) {
    Check-Stop
    $element=Body-Element $Window
    if(!$element){return (New-BodyCapture '' 'content_element_missing' $false $script:BodyCharLimit)}
    try{$text=Body-TextRange $Window $element;if($text -and $text.Trim()){return (New-BodyCapture $text 'uia_content_range' $true $script:BodyCharLimit)}}catch{if($_.Exception.Message -match 'CANCELLED|TIME_BUDGET|DESKTOP_LOCKED'){throw}}
    try{$text=Body-DescendantText $element;if($text -and $text.Trim()){return (New-BodyCapture $text 'uia_content_descendants' $true $script:BodyCharLimit)}}catch{if($_.Exception.Message -match 'CANCELLED|TIME_BUDGET|DESKTOP_LOCKED'){throw}}
    return (New-BodyCapture '' 'uia_body_unavailable' $false $script:BodyCharLimit)
}
function Read-ArticleBody($Window) {
    Check-Stop;$element=Body-Element $Window
    if(!$element){return (New-BodyCapture '' 'content_element_missing' $false $script:BodyCharLimit)}
    try{$text=Body-TextRange $Window $element;if($text.Trim()){return (New-BodyCapture $text 'uia_content_range' $true $script:BodyCharLimit)}}catch{if($_.Exception.Message -match 'CANCELLED|TIME_BUDGET|FOCUS_|DESKTOP_LOCKED'){throw}}
    try{$text=Body-DescendantText $element;if($text.Trim()){return (New-BodyCapture $text 'uia_content_descendants' $true $script:BodyCharLimit)}}catch{if($_.Exception.Message -match 'CANCELLED|TIME_BUDGET|FOCUS_|DESKTOP_LOCKED'){throw}}
    try{$text=Body-SelectionFallback $Window $element;if($text.Trim()){return (New-BodyCapture $text 'anchored_page_selection' $false $script:BodyCharLimit)}}catch{if($_.Exception.Message -match 'CANCELLED|TIME_BUDGET|FOCUS_|DESKTOP_LOCKED'){throw}}
    return (New-BodyCapture '' 'no_readable_plaintext' $false $script:BodyCharLimit)
}
function Body-CachePath([string]$Identity,[string]$RuntimeRoot) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity));$hash=([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return Join-Path (Join-Path $RuntimeRoot 'body-cache') ($hash+'.json')
}
function Get-BodyCache([string]$Identity,[string]$RuntimeRoot) {
    $path=Body-CachePath $Identity $RuntimeRoot
    if(!(Test-Path -LiteralPath $path)){return $null}
    try {
        $entry=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        $age=([datetimeoffset]::Now-[datetimeoffset]::Parse($entry.body_captured_at)).TotalHours
        if($entry.identity -cne $Identity -or !$entry.body_complete -or !$entry.body_text -or $entry.body_text.Length -gt $script:BodyCharLimit -or $age -gt 6 -or $age -lt 0){return $null}
        $result=@{};foreach($property in $entry.PSObject.Properties){if($property.Name -like 'body_*'){$result[$property.Name]=$property.Value}}
        $result.body_from_cache=$true;return $result
    }catch{return $null}
}
function Save-BodyCache([string]$Identity,[string]$RuntimeRoot,$Capture) {
    if(!$Capture.body_complete -or !$Capture.body_text){return}
    $path=Body-CachePath $Identity $RuntimeRoot;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    $entry=@{identity=$Identity};foreach($key in $Capture.Keys){if($key -like 'body_*' -and $key -ne 'body_from_cache'){$entry[$key]=$Capture[$key]}}
    Write-AtomicJson $path $entry
}
function Copy-BodyFields($Target,$Source) {foreach($key in $Source.Keys){if($key -like 'body_*'){$Target[$key]=$Source[$key]}}}
function Get-PublicRecord($Record) {
    $copy=@{}
    foreach($key in @('title','url','author','account','date','published_at_iso','publication_precision','content_type','identity','query','captured_at','within_window')){if($Record.ContainsKey($key)){$copy[$key]=$Record[$key]}}
    return $copy
}
