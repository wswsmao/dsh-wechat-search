param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$JobDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
$script:OwnedWindows=@{};$script:MainHandle=0;$script:SavedClipboard=$null;$script:WasMinimized=$false
$script:OriginalForeground=0;$script:Cleaning=$false;$lock=$null
$request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$packageRoot=Split-Path $PSScriptRoot -Parent;$runtimeRoot=Join-Path $packageRoot '.runtime'
$resolvedJob=[IO.Path]::GetFullPath($JobDir);$allowedRoot=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'jobs'))+[IO.Path]::DirectorySeparatorChar
if(!$resolvedJob.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Job directory must be inside plugin runtime jobs'}
if(!$request.keyword -or $request.keyword -isnot [string] -or $request.keyword.Length -gt 200 -or $request.lookback_days -lt 1 -or $request.lookback_days -gt 7 -or [int]$request.lookback_days -ne $request.lookback_days){throw 'Invalid request'}
$reference=([datetimeoffset]::Parse($request.reference_time)).ToOffset([timespan]::FromHours(8));$cutoff=$reference.AddDays(-[int]$request.lookback_days)
$timeoutMinutes=30;$delayMs=600;$maxRetries=2
if($request.settings){if($request.settings.timeout_minutes){$timeoutMinutes=[int]$request.settings.timeout_minutes};if($null -ne $request.settings.delay_ms){$delayMs=[int]$request.settings.delay_ms};if($null -ne $request.settings.max_retries){$maxRetries=[int]$request.settings.max_retries}}
$timeoutMinutes=[math]::Max(1,[math]::Min(120,$timeoutMinutes));$delayMs=[math]::Max(300,[math]::Min(10000,$delayMs));$maxRetries=[math]::Max(0,[math]::Min(3,$maxRetries))
$script:Deadline=[datetimeoffset]::Now.AddMinutes($timeoutMinutes)
$cancelPath=Join-Path $JobDir 'cancel.flag';$checkpointPath=Join-Path $JobDir 'checkpoint.json';$statusPath=Join-Path $JobDir 'status.json'
$resultsDir=Join-Path $JobDir 'results';[void][IO.Directory]::CreateDirectory($resultsDir)
$files=@{json=Join-Path $resultsDir 'result.json';csv=Join-Path $resultsDir 'result.csv'}
$script:Candidates=@();$script:Records=@();$script:Errors=@();$script:Processed=0;$script:Boundary=$false;$script:Exhausted=$false;$script:OrderingIssues=@();$script:LoadCounts=@();$script:Phase='initializing';$script:StopReason='';$script:Status='running';$script:PreviousCandidates=@()
if(Test-Path -LiteralPath $checkpointPath){$cp=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json;$script:PreviousCandidates=@($cp.candidates);$script:Candidates=@($cp.candidates);$script:Records=@();foreach($r in $cp.records){$h=@{};foreach($p in $r.PSObject.Properties){$h[$p.Name]=$p.Value};$script:Records+=$h}}
function Check-Stop {
    if($script:Cleaning){return}
    if(Test-Path -LiteralPath $cancelPath){throw 'CANCELLED'}
    if([datetimeoffset]::Now -gt $script:Deadline){throw 'TIME_BUDGET_EXCEEDED'}
    if($script:MainHandle -and ![WeChatNative]::InteractiveDesktop()){throw 'DESKTOP_LOCKED'}
}
function Publish-State {
    $seen=@{};$matches=@();$outside=@();$uncertain=@()
    foreach($record in $script:Records){if(!$record.identity){$record.identity=Get-ArticleIdentity $record.url};if($seen.ContainsKey($record.identity)){continue};$seen[$record.identity]=$true;$inside=Get-WindowMembership $record $cutoff $reference;$record.within_window=$inside;if($inside -eq $true){$matches+=$record}elseif($inside -eq $false){$outside+=$record}else{$uncertain+=$record}}
    $matches=@($matches|Sort-Object @{Expression={if($_.published_at_iso){$_.published_at_iso}else{$_.date}};Descending=$true})
    $scopeComplete=($script:Status -eq 'complete' -and ($script:Boundary -or $script:Exhausted) -and !$script:Errors.Count -and !$uncertain.Count -and !$script:OrderingIssues.Count)
    $coverage=@{search_boundary_reached=$script:Boundary;search_exhausted=$script:Exhausted;scope_complete=$scopeComplete;global_complete=$false;scope='WeChat search-visible latest results; no keyword expansion; no artificial result count limit'}
    $summary=@{id=$request.id;keyword=$request.keyword;lookback_days=[int]$request.lookback_days;status=$script:Status;phase=$script:Phase;started_at=$request.reference_time;reference_time=$reference.ToString('o');cutoff_time=$cutoff.ToString('o');updated_at=[datetimeoffset]::Now.ToString('o');worker_pid=$PID;manager_owner_pid=$request.manager_owner_pid;manager_owner_token=$request.manager_owner_token;counts=@{discovered=$script:Candidates.Count;processed=$script:Processed;matched=$matches.Count;failed=$script:Errors.Count;outside=$outside.Count;date_uncertain=$uncertain.Count};stop_reason=$script:StopReason;coverage=$coverage;files=$files;preview=@($matches|Select-Object -First 5);errors=@($script:Errors);ordering_issues=@($script:OrderingIssues);load_counts=@($script:LoadCounts)}
    $result=@{schema_version=1;job=$summary;records=@($matches);outside_records=@($outside);date_uncertain_records=@($uncertain);errors=@($script:Errors)}
    Write-AtomicJson $files.json $result;Write-ResultCsv $files.csv $matches
    Write-AtomicJson $checkpointPath @{keyword=$request.keyword;reference_time=$reference.ToString('o');candidates=@($script:Candidates);records=@($script:Records);errors=@($script:Errors)}
    Write-AtomicJson $statusPath $summary
}
try {
    [void][IO.Directory]::CreateDirectory($runtimeRoot)
    try{$lock=[IO.File]::Open((Join-Path $runtimeRoot 'desktop.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'DESKTOP_BUSY'}
    . (Join-Path $PSScriptRoot 'Desktop.ps1')
    $script:OriginalForeground=[WeChatNative]::GetForegroundWindow().ToInt64()
    $script:SavedClipboard=[Windows.Forms.Clipboard]::GetDataObject()
    $version=(Get-Process Weixin -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1).Path
    if($version -and (Get-Item -LiteralPath $version).VersionInfo.FileMajorPart -ne 4){throw 'WECHAT_VERSION_UNSUPPORTED'}
    Publish-State
    $search=Open-Search;$search=Search-Query $search $request.keyword
    $script:Phase='discovering';$stable=0;$priorCount=-1;$oldBatches=0;$lastItems=@()
    while($true){
        Check-Stop;$search=Find-Search;if(!$search){throw 'SEARCH_WINDOW_LOST'}
        $query=(Element-Id $search.root 'weixin-search-input').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if($query -cne $request.keyword){throw 'QUERY_CHANGED'}
        $latest=Element-Name $search.root '最新';if(!$latest -or $latest.Current.ClassName -notmatch 'selected'){throw 'LATEST_SORT_CHANGED'}
        $uiItems=Search-Items $search
        $text=Search-CopyText $search;Check-PageChallenge $search
        if(!$uiItems.Count){
            if($text -match '没有.*(结果|内容)|未找到|暂无.*结果'){$script:Exhausted=$true;break}
            $stable++;if($stable -ge 6){throw 'SEARCH_RESULTS_NOT_READY'};Desktop-Pause 600;continue
        }
        $titles=@($uiItems|ForEach-Object{$_.Current.Name});$parsed=ConvertFrom-SearchText $text $titles ([datetimeoffset]::Now);$text=$null
        if($lastItems.Count -gt 0){for($i=0;$i -lt [math]::Min($lastItems.Count,$parsed.Count);$i++){if((Normalize-Text $lastItems[$i].title) -cne (Normalize-Text $parsed[$i].title) -or (Normalize-Text $lastItems[$i].account) -cne (Normalize-Text $parsed[$i].account)){throw 'SEARCH_LIST_REORDERED'}}}
        $script:Candidates=@($parsed);$script:LoadCounts+=$parsed.Count
        for($i=1;$i -lt $parsed.Count;$i++){if($null -ne $parsed[$i].age_seconds -and $null -ne $parsed[$i-1].age_seconds -and $parsed[$i].age_seconds -lt $parsed[$i-1].age_seconds){$script:OrderingIssues+=@{type='relative_date_inversion';index=$i};break}}
        $old=@($parsed|Where-Object{$null -ne $_.age_seconds -and $_.age_seconds -ge ([int]$request.lookback_days+1)*86400})
        if($old.Count -ge 3){$script:Boundary=$true;$oldBatches++}
        if($parsed.Count -eq $priorCount){$stable++}else{$stable=0};$priorCount=$parsed.Count;$lastItems=$parsed
        Publish-State
        # Require a following load attempt after multiple clearly old results, not a single old article.
        if($script:Boundary -and $oldBatches -ge 2){break}
        if($stable -ge 3){$script:Exhausted=$true;break}
        Scroll-SearchEnd $search $uiItems
    }
    # Preserve pending candidates from the previous attempt. Never erase missing work on resume.
    $currentKeys=@{};foreach($c in $script:Candidates){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);$currentKeys[$k]=$true}
    foreach($old in $script:PreviousCandidates){$k=(Normalize-Text $old.title)+'|'+(Normalize-Text $old.account);if(!$currentKeys.ContainsKey($k)){$h=@{title=$old.title;account=$old.account;relative_date=$old.relative_date;age_seconds=$old.age_seconds;index=-1};$script:Candidates+=$h;$currentKeys[$k]=$true}}
    $script:Phase='extracting';Publish-State
    $cached=@{};foreach($record in $script:Records){$key=(Normalize-Text $record.title)+'|'+(Normalize-Text $record.account);$cached[$key]=$record}
    $keyCounts=@{};foreach($c in $script:Candidates){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);if(!$keyCounts.ContainsKey($k)){$keyCounts[$k]=0};$keyCounts[$k]++}
    $lastExact=$null
    foreach($candidate in $script:Candidates){
        Check-Stop;$script:Processed++;$key=(Normalize-Text $candidate.title)+'|'+(Normalize-Text $candidate.account)
        if($cached.ContainsKey($key) -and $keyCounts[$key] -eq 1){continue}
        $success=$false;$failure='';$article=$null
        for($attempt=0;$attempt -le $maxRetries;$attempt++){
            Check-Stop
            try{
                $search=Find-Search;if(!$search){throw 'SEARCH_WINDOW_LOST'}
                $actual=(Element-Id $search.root 'weixin-search-input').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value;if($actual -cne $request.keyword){throw 'QUERY_CHANGED'}
                $items=Search-Items $search;$e=$null
                if($candidate.index -lt $items.Count -and (Normalize-Text $items[$candidate.index].Current.Name) -ceq (Normalize-Text $candidate.title)){$e=$items[$candidate.index]}
                if(!$e){throw 'SEARCH_INDEX_CHANGED'}
                $article=Open-Candidate $search $e $candidate $reference
                $record=$article.record;$record.url=Read-PublicUrl $article.window;$record.identity=Get-ArticleIdentity $record.url;$record.captured_at=[datetimeoffset]::Now.ToString('o');$record.source='logged-in WeChat desktop';$record.query=$request.keyword
                if($record.published_at_iso){$dt=[datetimeoffset]::Parse($record.published_at_iso);if($lastExact -and $dt -gt $lastExact){$script:OrderingIssues+=@{type='exact_date_inversion';index=$candidate.index}};$lastExact=$dt}
                $script:Records+=$record;$cached[$key]=$record;$success=$true;Close-OwnedArticle $article.window;break
            }catch{
                $failure=$_.Exception.Message
                if($failure -match 'CANCELLED|TIME_BUDGET|DESKTOP_LOCKED|CHALLENGE|QUERY_CHANGED|SORT_CHANGED|FOCUS_UNAVAILABLE|FOCUS_CHANGED'){throw}
                if($article){Close-OwnedArticle $article.window};Desktop-Pause 500
            }
        }
        if(!$success){$script:Errors+=@{title=$candidate.title;account=$candidate.account;index=$candidate.index;reason=$failure}}
        Publish-State;Desktop-Pause $delayMs
    }
    $uncertainDates=@($script:Records|Where-Object{$null -eq (Get-WindowMembership $_ $cutoff $reference)})
    if($script:Errors.Count -or $script:OrderingIssues.Count -or $uncertainDates.Count){$script:Status='partial';$script:StopReason='ARTICLE_ERRORS_OR_ORDERING_UNCERTAINTY'}else{$script:Status='complete';$script:StopReason=if($script:Boundary){'TIME_WINDOW_BOUNDARY_REACHED'}else{'SEARCH_EXHAUSTED'}}
    $script:Phase='finished';Publish-State
}catch{
    $reason=$_.Exception.Message;$script:StopReason=$reason
    if($reason -eq 'CANCELLED'){$script:Status='cancelled'}elseif($reason -match 'LOCKED|CHALLENGE|NOT_LOGGED|VERSION_UNSUPPORTED|SEARCH_UNAVAILABLE|FOCUS_UNAVAILABLE|FOCUS_CHANGED'){$script:Status='needs_user'}elseif($reason -eq 'TIME_BUDGET_EXCEEDED'){$script:Status='partial'}else{$script:Status='failed'}
    $script:Phase='stopped';try{Publish-State}catch{Write-Error 'Failed to persist worker state' -ErrorAction Continue}
}finally{
    $script:Cleaning=$true
    if(Get-Command Desktop-Cleanup -ErrorAction SilentlyContinue){try{Desktop-Cleanup}catch{}}
    if($lock){$lock.Dispose()}
}
Write-Output ("wechat-search job={0} status={1} records={2}" -f $request.id,$script:Status,$script:Records.Count)
