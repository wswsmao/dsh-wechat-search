Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$nativeRoot=if($script:CollectorDir){$script:CollectorDir}else{$PSScriptRoot}
Add-Type -Path (Join-Path $nativeRoot 'Native.cs')
[void][WeChatNative]::SetProcessDpiAwarenessContext([IntPtr](-4));[void][WeChatNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
function Element-Id($Root,[string]$Id){$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty),$Id))}
function Element-Name($Root,[string]$Name){$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty),$Name))}
function Element-Document($Root){$Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),([System.Windows.Automation.ControlType]::Document)))}
function Desktop-Pause([int]$Ms=300){$until=[datetime]::UtcNow.AddMilliseconds($Ms);while([datetime]::UtcNow -lt $until){Check-Stop;Start-Sleep -Milliseconds 100}}
function Activate-Window([long]$Handle){Check-Stop;if(![WeChatNative]::IsWindow([IntPtr]$Handle)){throw 'WINDOW_LOST'};[void][WeChatNative]::SetForegroundWindow([IntPtr]$Handle);Desktop-Pause 150;if(![WeChatNative]::IsForeground($Handle)){throw 'FOCUS_UNAVAILABLE'}}
function Click-Element($Element,[long]$Handle){
    if(!$Element){throw 'UI_ELEMENT_MISSING'};Check-Stop
    $p=$null;if($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$p)){$p.Invoke();return}
    $r=$Element.Current.BoundingRectangle;if($r.IsEmpty -or $Element.Current.IsOffscreen){throw 'UI_ELEMENT_OFFSCREEN'}
    Activate-Window $Handle;[WeChatNative]::Click([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))
}
function Browser-Windows {
    $ids=[uint32[]]@((Get-Process Weixin,WeChatAppEx -ErrorAction SilentlyContinue).Id)
    foreach($h in [WeChatNative]::BrowserHandles($script:MainHandle,$ids)){
        try{$root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h);$doc=Element-Document $root;if($doc){@{handle=$h;root=$root;document=$doc}}}catch{}
    }
}
function Find-Search {
    foreach($w in Browser-Windows){try{if(Element-Id $w.root 'weixin-search-input'){return $w}}catch{}}
    return $null
}
function Get-MainWindow {
    $p=Get-Process Weixin -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1
    if(!$p){throw 'WECHAT_NOT_LOGGED_IN_OR_NOT_RUNNING'}
    $script:MainHandle=$p.MainWindowHandle.ToInt64();return $p
}
function Open-Search {
    $p=Get-MainWindow
    if(![WeChatNative]::InteractiveDesktop()){throw 'DESKTOP_LOCKED'}
    $script:WasMinimized=[WeChatNative]::IsIconic([IntPtr]$script:MainHandle)
    [void][WeChatNative]::ShowWindow([IntPtr]$script:MainHandle,9);Activate-Window $script:MainHandle
    # Minimized browser windows are not enumerable via UIA; restore them before searching.
    foreach($q in Get-Process Weixin,WeChatAppEx -ErrorAction SilentlyContinue){if($q.MainWindowHandle -ne 0 -and [WeChatNative]::IsIconic($q.MainWindowHandle)){[void][WeChatNative]::ShowWindow($q.MainWindowHandle,9)}}
    Desktop-Pause 400
    $w=Find-Search;if($w){return $w}
    # Qt main UI has no accessible controls. Use DPI-scaled relative anchors on the verified 4.x layout only.
    $r=New-Object WeChatNative+Rect;[void][WeChatNative]::GetWindowRect([IntPtr]$script:MainHandle,[ref]$r)
    $scale=[WeChatNative]::GetDpiForWindow([IntPtr]$script:MainHandle)/96.0
    if(($r.Right-$r.Left)/$scale -lt 700 -or ($r.Bottom-$r.Top)/$scale -lt 500){throw 'WECHAT_LAYOUT_UNSUPPORTED'}
    [WeChatNative]::Click([int]($r.Left+36*$scale),[int]($r.Top+256*$scale));Desktop-Pause 500
    [WeChatNative]::Click([int]($r.Left+140*$scale),[int]($r.Top+200*$scale))
    for($i=0;$i -lt 50;$i++){Desktop-Pause 200;$w=Find-Search;if($w){return $w}}
    throw 'WECHAT_SEARCH_UNAVAILABLE_OPEN_DISCOVER_SEARCH_MANUALLY'
}
function Search-Query($Search,[string]$Keyword){
    $input=Element-Id $Search.root 'weixin-search-input';if(!$input){throw 'SEARCH_INPUT_MISSING'}
    $input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Keyword)
    Click-Element (Element-Name $Search.root '搜索') $Search.handle
    Desktop-Pause 1000
    # Search entry may be 'all' or home; results have anonymous article tabs at document-relative anchor.
    $w=Find-Search;if(!$w){throw 'SEARCH_WINDOW_LOST'}
    # Tab labels are not exposed via UIA names; probe each tab and verify via the document title.
    if($w.document.Current.Name -notmatch '文章'){
        Activate-Window $w.handle;$r=$w.document.Current.BoundingRectangle;$dpi=[WeChatNative]::GetDpiForWindow([IntPtr]$w.handle)/96.0
        $tabs=@();$all=$w.document.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        foreach($e in $all){if($e.Current.ClassName -like '*unit__item*' -and !$e.Current.BoundingRectangle.IsEmpty){$c=$e.Current.BoundingRectangle;if($c.X+$c.Width/2 -gt $r.X -and $c.X+$c.Width/2 -lt $r.X+$r.Width){$tabs+=$e}}}
        $tabs=@($tabs|Sort-Object {$_.Current.BoundingRectangle.X})
        foreach($t in $tabs){
            $c=$t.Current.BoundingRectangle
            [WeChatNative]::Click([int]($c.X+$c.Width/2),[int]($c.Y+$c.Height/2));Desktop-Pause 900
            $w=Find-Search;if(!$w){break}
            if($w.document.Current.Name -match '文章'){break}
        }
        if(!$w -or $w.document.Current.Name -notmatch '文章'){throw 'ARTICLE_TAB_UNAVAILABLE'}
    }
    for($i=0;$i -lt 50;$i++){Desktop-Pause 200;$w=Find-Search;if($w -and (Element-Name $w.root '最新')){break}}
    $latest=Element-Name $w.root '最新';if(!$latest){throw 'ARTICLE_LATEST_FILTER_UNAVAILABLE'}
    if($latest.Current.ClassName -notmatch 'selected'){Click-Element $latest $w.handle;Desktop-Pause 1000}
    $value=(Element-Id $w.root 'weixin-search-input').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if($value -cne $Keyword){throw 'QUERY_CHANGED'}
    # Query refresh is asynchronous even when the previous document title matches.
    $signature='';$stable=0
    for($i=0;$i -lt 30;$i++){Desktop-Pause 500;$w=Find-Search;$items=Search-Items $w;$next=($items|ForEach-Object{$_.Current.Name}) -join '|';if($next -and $next -ceq $signature){$stable++}else{$stable=0};$signature=$next;if($stable -ge 3){break}}
    return $w
}
function Search-Items($Search){
    $all=$Search.document.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);$items=@()
    foreach($e in $all){if($e.Current.ClassName -like '*search_list_item*'){$items+=$e}}
    return ,$items
}
function Search-CopyText($Search){
    Activate-Window $Search.handle;$r=$Search.document.Current.BoundingRectangle
    [WeChatNative]::Click([int]($r.X+50),[int]($r.Y+[math]::Min(600,$r.Height-200)))
    if(![WeChatNative]::IsForeground($Search.handle)){throw 'FOCUS_UNAVAILABLE'}
    [Windows.Forms.Clipboard]::Clear();[Windows.Forms.SendKeys]::SendWait('^a^c');Desktop-Pause 200
    if(![WeChatNative]::IsForeground($Search.handle)){throw 'FOCUS_CHANGED'}
    $text=[Windows.Forms.Clipboard]::GetText();[Windows.Forms.SendKeys]::SendWait('{ESC}')
    return $text
}
function Scroll-SearchEnd($Search,$Items){
    if(!$Items.Count){return};$p=$null;if($Items[-1].TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$p)){$p.ScrollIntoView()}
    Activate-Window $Search.handle;$r=$Search.document.Current.BoundingRectangle;[WeChatNative]::Wheel([int]($r.Right-100),[int]($r.Bottom-180));Desktop-Pause 1200
}
function Read-ArticleHeader($Window,$Candidate,[datetimeoffset]$Reference){
    $at=Element-Id $Window.root 'activity-name';$acct=Element-Id $Window.root 'js_name'
    if($at -and $acct){
        if((Normalize-Text $at.Current.Name) -cne (Normalize-Text $Candidate.title) -or (Normalize-Text $acct.Current.Name) -cne (Normalize-Text $Candidate.account)){return $null}
        $all=$Window.document.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);$past=$false;$date='';$author=''
        foreach($e in $all){$c=$e.Current;if($c.AutomationId -eq 'activity-name'){$past=$true;continue};if(!$past){continue};if($c.AutomationId -eq 'js_content' -or $c.ClassName -match 'rich_media_content'){break};if($c.ControlType -eq [System.Windows.Automation.ControlType]::Text){if($c.Name -match '^\d{4}年\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}$'){$date=$c.Name;break};if($c.Name -and $c.Name -ne '原创'){$author=$c.Name}}}
        if(!$date){return $null};$dt=[datetime]::ParseExact($date,'yyyy年M月d日 HH:mm',[Globalization.CultureInfo]::InvariantCulture)
        return @{title=$at.Current.Name;author=$author;account=$acct.Current.Name;date=$dt.ToString('yyyy-MM-dd');published_at_iso=([datetimeoffset]::new($dt,[timespan]::FromHours(8))).ToString('o');publication_precision='minute';content_type='article'}
    }
    $share=Element-Id $Window.root 'js_text_desc';if(!$share){$share=Element-Id $Window.root 'js_video_page_title'};if(!$share -or (Normalize-Text $Window.document.Current.Name) -cne (Normalize-Text $Candidate.title)){return $null}
    $all=$Window.document.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);$label='';$account=''
    foreach($e in $all){if($e.Current.ClassName -match 'rich_media_meta_list_combine'){$label=$e.Current.Name};if($e.Current.AutomationId -eq 'js_wx_follow_nickname'){$account=$e.Current.Name}}
    $relativeStamp=$null
    if($label -match '(今天|昨天|前天)\s*(\d{1,2}:\d{2})'){$days=@{'今天'=0;'昨天'=1;'前天'=2}[$Matches[1]];$clock=$Matches[2];$dt=([datetimeoffset]::Now.ToOffset([timespan]::FromHours(8))).Date.AddDays(-$days);$time=[datetime]::ParseExact($clock,'H:mm',[Globalization.CultureInfo]::InvariantCulture);$dt=$dt.AddHours($time.Hour).AddMinutes($time.Minute);$relativeStamp=[datetimeoffset]::new($dt,[timespan]::FromHours(8))}
    if($relativeStamp){if(!$account){$account=$Candidate.account};if((Normalize-Text $account) -cne (Normalize-Text $Candidate.account)){return $null};return @{title=$Window.document.Current.Name;author='';account=$account;date=$relativeStamp.ToString('yyyy-MM-dd');published_at_iso=$relativeStamp.ToString('o');publication_precision='minute';content_type=$(if(Element-Id $Window.root 'js_video_page_title'){'video_share'}else{'text_share'});date_year_basis='visible relative publication date'}}
    if(!$label -or $label -notmatch '(\d{1,2})月(\d{1,2})日'){return $null};$month=[int]$Matches[1];$day=[int]$Matches[2]
    $ageReference=if($Candidate.age_reference){[datetimeoffset]::Parse($Candidate.age_reference)}else{$Reference};$estimated=$ageReference.AddSeconds(-[double]$Candidate.age_seconds);$possible=@();foreach($year in @(($Reference.Year-1),$Reference.Year,($Reference.Year+1))){try{$d=[datetime]::new($year,$month,$day);$possible+=@{date=$d;distance=[math]::Abs(($d-$estimated.DateTime).TotalDays)}}catch{}}
    $chosen=$possible|Sort-Object {$_.distance}|Select-Object -First 1;if(!$chosen -or $chosen.distance -gt 2){return $null}
    if(!$account){$account=$Candidate.account};if((Normalize-Text $account) -cne (Normalize-Text $Candidate.account)){return $null}
    return @{title=$Window.document.Current.Name;author='';account=$account;date=$chosen.date.ToString('yyyy-MM-dd');published_at_iso=$null;publication_precision='day';content_type=$(if(Element-Id $Window.root 'js_video_page_title'){'video_share'}else{'text_share'});date_year_basis='search relative date corroboration'}
}
function Read-PublicUrl($Window){
    for($i=0;$i -lt 25;$i++){
        Check-Stop;try{$value=$Window.document.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value;return (ConvertTo-PublicArticleUrl $value)}catch{Desktop-Pause 200}
    }
    throw 'ARTICLE_PUBLIC_URL_UNAVAILABLE'
}
function Check-PageChallenge($Window){
    # Article prose can mention verification; only classify a standalone challenge surface.
    if((Element-Id $Window.root 'activity-name') -or (Element-Id $Window.root 'js_text_desc') -or (Element-Id $Window.root 'weixin-search-input')){return}
    try{$text=$Window.document.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(3000);if($text -match '访问过于频繁|操作过于频繁|请完成.*验证|安全验证|验证码|环境异常') {throw 'WECHAT_CHALLENGE'}}catch{if($_.Exception.Message -eq 'WECHAT_CHALLENGE'){throw}}
}
function Open-Candidate($Search,$Element,$Candidate,[datetimeoffset]$Reference){
    $beforeWindows=@(Browser-Windows);$before=@($beforeWindows|ForEach-Object{$_.handle});$beforeUrls=@{};foreach($w in $beforeWindows){try{$beforeUrls[$w.handle]=$w.document.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value}catch{}};Click-Element $Element $Search.handle
    for($i=0;$i -lt 60;$i++){
        Desktop-Pause 200
        foreach($w in Browser-Windows){if($w.handle -eq $Search.handle){continue};if($w.handle -notin $before){$script:OwnedWindows[$w.handle]=$true};$changed=$false;try{$changed=$beforeUrls[$w.handle] -cne $w.document.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value}catch{};if($w.handle -in $before -and !$changed){continue};Check-PageChallenge $w;$header=Read-ArticleHeader $w $Candidate $Reference;if($header){return @{window=$w;record=$header}}}
    }
    throw 'ARTICLE_HEADER_UNAVAILABLE'
}
function Native-Drag {
    param([int]$FromX,[int]$FromY,[int]$ToX,[int]$ToY,[int]$Steps=20,[int]$StepMs=30)
    [WeChatNative]::SetCursorPos($FromX,$FromY);Desktop-Pause 200
    [WeChatNative]::MouseDown($FromX,$FromY);Desktop-Pause 200
    for($i=1;$i -le $Steps;$i++){
        $x=[int]($FromX+($ToX-$FromX)*$i/$Steps);$y=[int]($FromY+($ToY-$FromY)*$i/$Steps)
        [WeChatNative]::SetCursorPos($x,$y);Desktop-Pause $StepMs
    }
    [WeChatNative]::MouseUp($ToX,$ToY);Desktop-Pause 200
}
function Window-Rect([long]$Handle){
    $r=New-Object WeChatNative+Rect;[void][WeChatNative]::GetWindowRect([IntPtr]$Handle,[ref]$r)
    return @{Left=$r.Left;Top=$r.Top;Right=$r.Right;Bottom=$r.Bottom;Width=$r.Right-$r.Left;Height=$r.Bottom-$r.Top}
}
# Tear the active tab out of an article window's tab strip so it becomes an independent window.
# The tab strip is a native widget and is NOT in the UIA tree; it sits above the document rect.
# Grab point is derived from the document offset so it adapts to DPI and window width.
function Tear-Off-Window($Window){
    if(!$Window){return $false}
    $handle=$Window.handle
    try{
        $rect=Window-Rect $handle
        $doc=$Window.document.Current.BoundingRectangle
        if($doc.IsEmpty){return $false}
        # Tab strip occupies the band between the window top and the document top.
        $stripHeight=[int]($doc.Y-$rect.Top)
        if($stripHeight -lt 20){return $false}
        $grabY=[int]($rect.Top+[Math]::Min(55,$stripHeight*0.55))
        $grabX=[int]($rect.Left+700)
        if($grabX -gt $rect.Right-40){$grabX=[int]($rect.Left+$rect.Width*0.4)}
        Activate-Window $handle
        Native-Drag -FromX $grabX -FromY $grabY -ToX ($grabX+300) -ToY ($grabY+760)
        return $true
    }catch{return $false}
}
function Close-OwnedArticle($Window){
    # Close only tabs/windows created by this worker, never a pre-existing user's browser.
    if(!$Window -or !$script:OwnedWindows.ContainsKey($Window.handle)){return}
    try{$buttons=$Window.root.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty),'关闭'));if($buttons.Count){Click-Element $buttons[0] $Window.handle;Desktop-Pause 150}}catch{}
}
function Desktop-Cleanup {
    foreach($w in Browser-Windows){if($script:OwnedWindows.ContainsKey($w.handle)){try{$close=Element-Name $w.root '关闭';if($close){Click-Element $close $w.handle}}catch{}}}
    if($script:SavedClipboard){try{[Windows.Forms.Clipboard]::SetDataObject($script:SavedClipboard,$true)}catch{}}
    if($script:WasMinimized){[void][WeChatNative]::ShowWindow([IntPtr]$script:MainHandle,6)}
    if($script:OriginalForeground -and [WeChatNative]::IsWindow([IntPtr]$script:OriginalForeground)){[void][WeChatNative]::SetForegroundWindow([IntPtr]$script:OriginalForeground)}
}
