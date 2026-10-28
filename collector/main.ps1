param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$JobDir)
$ErrorActionPreference='Stop'
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Core.ps1'),[Text.Encoding]::UTF8)))
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Body.ps1'),[Text.Encoding]::UTF8)))
$script:OwnedWindows=@{};$script:IgnoredWindows=@{};$script:Skipped=@();$script:MainHandle=0;$script:SavedClipboard=$null;$script:WasMinimized=$false
$script:OriginalForeground=0;$script:Cleaning=$false;$lock=$null
$request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$packageRoot=Split-Path $PSScriptRoot -Parent;$runtimeRoot=Join-Path $packageRoot '.runtime'
$resolvedJob=[IO.Path]::GetFullPath($JobDir);$allowedRoot=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'jobs'))+[IO.Path]::DirectorySeparatorChar
if(!$resolvedJob.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Job directory must be inside plugin runtime jobs'}
if(!$request.keyword -or $request.keyword -isnot [string] -or $request.keyword.Length -gt 200 -or $request.lookback_days -lt 1 -or $request.lookback_days -gt 7 -or [int]$request.lookback_days -ne $request.lookback_days){throw 'Invalid request'}
$reference=([datetimeoffset]::Parse($request.reference_time)).ToOffset([timespan]::FromHours(8));$cutoff=$reference.AddDays(-[int]$request.lookback_days)
if($reference -gt [datetimeoffset]::Now){throw 'Future reference_time is not allowed'}
if($null -ne $request.include_body -and $request.include_body -isnot [bool]){throw 'include_body must be boolean'}
$includeBody=($request.include_body -eq $true)
$listOnly=($request.list_only -eq $true)
function Get-StableKey([string]$Title,[string]$Account){return (Normalize-Text $Title)+'|'+(Normalize-Text $Account)}
$timeoutMinutes=30;$delayMs=250;$maxRetries=1
if($request.settings){if($request.settings.timeout_minutes){$timeoutMinutes=[int]$request.settings.timeout_minutes};if($null -ne $request.settings.delay_ms){$delayMs=[int]$request.settings.delay_ms};if($null -ne $request.settings.max_retries){$maxRetries=[int]$request.settings.max_retries}}
$timeoutMinutes=[math]::Max(1,[math]::Min(120,$timeoutMinutes));$delayMs=[math]::Max(120,[math]::Min(10000,$delayMs));$maxRetries=[math]::Max(0,[math]::Min(3,$maxRetries))
$script:Deadline=[datetimeoffset]::Now.AddMinutes($timeoutMinutes)
$cancelPath=Join-Path $JobDir 'cancel.flag';$checkpointPath=Join-Path $JobDir 'checkpoint.json';$statusPath=Join-Path $JobDir 'status.json'
$resultsDir=Join-Path $JobDir 'results';[void][IO.Directory]::CreateDirectory($resultsDir)
$files=@{json=Join-Path $resultsDir 'result.json';csv=Join-Path $resultsDir 'result.csv'}
# Stage 2: read bodies for a batch of already-open, detached windows, then close them.
# Bodies are read through UIA only (no clipboard), so concurrent windows cannot corrupt each other.
function Read-Opened-Batch($Batch,$Cutoff,$Reference,[bool]$IncludeBody,$RuntimeRoot,[ref]$Cached){
    foreach($entry in $Batch){
        Check-Stop
        $record=$entry.record;$window=$entry.window
        try{
            # If tearing the tab off failed, WeChat may have navigated this same window to another
            # article. Reading it then would attach the wrong body to this record, so verify first.
            if($IncludeBody -and $entry.membership -eq $true){
                $liveTitle=''
                try{$liveTitle=Read-PublicUrl $window}catch{}
                try{
                    $liveId=Element-Id $window.root 'activity-name'
                    if($liveId){
                        $liveTitle=$liveId.Current.Name
                        if((Normalize-Text $liveTitle) -cne (Normalize-Text $record.title)){
                            throw "WINDOW_NAVIGATED_AWAY expected='$($record.title)' actual='$liveTitle'"
                        }
                    }
                }catch{if($_.Exception.Message -match 'WINDOW_NAVIGATED_AWAY'){throw}}
                $body=$null
                $body=Get-BodyCache $record.identity $RuntimeRoot
                if(!$body){
                    $body=Read-ArticleBody-UiaOnly $window
                    if($body -and $body.body_text){try{Save-BodyCache $record.identity $RuntimeRoot $body}catch{}}
                }
                if($body){Copy-BodyFields $record $body}
                else{Copy-BodyFields $record @{body_text='';body_status='unavailable';body_chars=0;body_complete=$false;body_truncated=$false}}
            }else{
                Copy-BodyFields $record @{body_text='';body_status=$(if($IncludeBody){'not_requested_outside_or_uncertain_window'}else{'not_requested'});body_chars=0;body_complete=$false;body_truncated=$false}
            }
            $prior=@($script:Records|Where-Object{$_.identity -ceq $record.identity})|Select-Object -First 1
            if($IncludeBody -and !$record.body_complete -and $prior -and $prior.body_complete){Copy-BodyFields $record $prior;$record.body_from_cache=$true}
            $script:Records=@($script:Records|Where-Object{$_.identity -cne $record.identity})+@($record)
            if($Cached -and $Cached.Value){$Cached.Value[$entry.key]=$record}
        }catch{
            $script:Errors+=@{title=$record.title;account=$record.account;index=$entry.candidate.index;reason=$_.Exception.Message}
        }finally{
            try{Close-OwnedArticle $window}catch{}
        }
    }
    Publish-State
}
$script:Candidates=@();$script:Records=@();$script:Errors=@();$script:Processed=0;$script:Boundary=$false;$script:Exhausted=$false;$script:OrderingIssues=@();$script:LoadCounts=@();$script:Phase='initializing';$script:StopReason='';$script:Status='running';$script:PreviousCandidates=@()
if(Test-Path -LiteralPath $checkpointPath){$cp=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json;$script:PreviousCandidates=if($cp.pending_candidates){@($cp.pending_candidates)}else{@($cp.candidates)};$script:Candidates=@($cp.candidates);if($cp.ordering_issues){$script:OrderingIssues=@($cp.ordering_issues)};$script:Records=@();foreach($r in $cp.records){$h=@{};foreach($p in $r.PSObject.Properties){$h[$p.Name]=$p.Value};$script:Records+=$h}}
function Check-Stop {
    if($script:Cleaning){return}
    if(Test-Path -LiteralPath $cancelPath){throw 'CANCELLED'}
    if([datetimeoffset]::Now -gt $script:Deadline){throw 'TIME_BUDGET_EXCEEDED'}
    if($script:MainHandle -and ![WeChatNative]::InteractiveDesktop()){throw 'DESKTOP_LOCKED'}
}
function Publish-State {
    $seen=@{};$matches=@();$outside=@();$uncertain=@()
    foreach($record in $script:Records){
        if(!$record.identity){$record.identity=Get-ArticleIdentity $record.url}
        if($seen.ContainsKey($record.identity)){continue}
        $seen[$record.identity]=$true
        # List-only rows carry no precise date yet (the list shows "2天前" style labels), so a window
        # test would classify every one of them as uncertain and return an empty list. They are the
        # pre-screen input, not final results: hand them all to the caller.
        if($record.list_only){$record.within_window=$null;$matches+=$record;continue}
        $inside=Get-WindowMembership $record $cutoff $reference;$record.within_window=$inside;if($inside -eq $true){$matches+=$record}elseif($inside -eq $false){$outside+=$record}else{$uncertain+=$record}
    }
    $matches=@($matches|Sort-Object @{Expression={if($_.published_at_iso){$_.published_at_iso}else{$_.date}};Descending=$true})
    $bodyIncomplete=@($matches|Where-Object{$includeBody -and !$_.body_complete})
    $bodyRead=@($matches|Where-Object{$_.body_text})
    # Skipping a labelled non-article row is correct behaviour, not a failure: it must not be reported
    # as an extraction error, and it must not block scope completion.
    $script:SkippedNonArticle=$script:Skipped.Count
    $realErrors=$script:Errors.Count
    $scopeComplete=($script:Status -eq 'complete' -and ($script:Boundary -or $script:Exhausted) -and !$realErrors -and !$uncertain.Count -and !$script:OrderingIssues.Count -and !$bodyIncomplete.Count)
    $coverage=@{search_boundary_reached=$script:Boundary;search_exhausted=$script:Exhausted;scope_complete=$scopeComplete;global_complete=$false;body_requested=$includeBody;body_complete=($includeBody -and $script:Phase -eq 'finished' -and $script:Processed -ge $script:Candidates.Count -and !$bodyIncomplete.Count);scope='WeChat search-visible latest results; no keyword expansion; no artificial result count limit'}
    $summary=@{id=$request.id;keyword=$request.keyword;lookback_days=[int]$request.lookback_days;status=$script:Status;phase=$script:Phase;started_at=$request.reference_time;reference_time=$reference.ToString('o');cutoff_time=$cutoff.ToString('o');updated_at=[datetimeoffset]::Now.ToString('o');worker_pid=$PID;manager_owner_pid=$request.manager_owner_pid;manager_owner_token=$request.manager_owner_token;include_body=$includeBody;counts=@{discovered=$script:Candidates.Count;processed=$script:Processed;matched=$matches.Count;failed=$script:Errors.Count;outside=$outside.Count;date_uncertain=$uncertain.Count;body_read=$bodyRead.Count;body_incomplete=$bodyIncomplete.Count};stop_reason=$script:StopReason;coverage=$coverage;files=$files;preview=@($matches|Select-Object -First 5|ForEach-Object{Get-PublicRecord $_});errors=@($script:Errors);skipped_non_article=@($script:Skipped);ordering_issues=@($script:OrderingIssues);load_counts=@($script:LoadCounts)}
    $result=@{schema_version=1;job=$summary;records=@($matches);outside_records=@($outside);date_uncertain_records=@($uncertain);errors=@($script:Errors)}
    Write-AtomicJson $files.json $result;Write-ResultCsv $files.csv $matches
    Write-AtomicJson $checkpointPath @{keyword=$request.keyword;reference_time=$reference.ToString('o');candidates=@($script:Candidates);pending_candidates=@($script:PreviousCandidates);records=@($script:Records);errors=@($script:Errors);ordering_issues=@($script:OrderingIssues)}
    Write-AtomicJson $statusPath $summary
}
try {
    [void][IO.Directory]::CreateDirectory($runtimeRoot)
    try{$lock=[IO.File]::Open((Join-Path $runtimeRoot 'desktop.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'DESKTOP_BUSY'}
    $script:CollectorDir=$PSScriptRoot
    . ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Desktop.ps1'),[Text.Encoding]::UTF8)))
    $script:OriginalForeground=[WeChatNative]::GetForegroundWindow().ToInt64()
    $script:SavedClipboard=[Windows.Forms.Clipboard]::GetDataObject()
    $version=(Get-Process Weixin -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowHandle -ne 0}|Select-Object -First 1).Path
    if($version -and (Get-Item -LiteralPath $version).VersionInfo.FileMajorPart -ne 4){throw 'WECHAT_VERSION_UNSUPPORTED'}
    Publish-State
    $search=Open-Search;$search=Search-Query $search $request.keyword
    $script:Phase='discovering';$stable=0;$priorCount=-1;$lastItems=@()
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
        # Stop scrolling once the list is clearly past the window. Results are newest-first, so every
        # row below the boundary is unusable. Counting cumulatively (not per batch) matters: the
        # first page already held 38 of 56 rows outside the window, yet the old per-batch rule needed
        # two consecutive pages of old rows and kept scrolling through a month of dead results.
        $old=@($parsed|Where-Object{$null -ne $_.age_seconds -and $_.age_seconds -ge (([datetimeoffset]::Now-$cutoff).TotalSeconds+86400)})
        if($old.Count -ge 3){$script:Boundary=$true}
        if($parsed.Count -eq $priorCount){$stable++}else{$stable=0};$priorCount=$parsed.Count;$lastItems=$parsed
        Publish-State
        # A boundary hit is enough: newer rows can only be above them, and we have already read them.
        if($script:Boundary){break}
        if($stable -ge 3){$script:Exhausted=$true;break}
        Scroll-SearchEnd $search $uiItems
    }
    # Preserve pending candidates from the previous attempt. Never erase missing work on resume.
    $currentKeys=@{};foreach($c in $script:Candidates){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);if(!$currentKeys.ContainsKey($k)){$currentKeys[$k]=0};$currentKeys[$k]++}
    $oldCounts=@{};foreach($old in $script:PreviousCandidates){$k=(Normalize-Text $old.title)+'|'+(Normalize-Text $old.account);if(!$oldCounts.ContainsKey($k)){$oldCounts[$k]=0};$oldCounts[$k]++;if(!$currentKeys.ContainsKey($k) -or $oldCounts[$k] -gt $currentKeys[$k]){$h=@{title=$old.title;account=$old.account;relative_date=$old.relative_date;age_seconds=$old.age_seconds;index=-1};$script:Candidates+=$h}}
    $script:PreviousCandidates=@($script:Candidates)
    $script:Phase='extracting';Publish-State
    $cached=@{};foreach($record in $script:Records){$key=(Normalize-Text $record.title)+'|'+(Normalize-Text $record.account);$cached[$key]=$record}
    $keyCounts=@{};foreach($c in $script:Candidates){$k=(Normalize-Text $c.title)+'|'+(Normalize-Text $c.account);if(!$keyCounts.ContainsKey($k)){$keyCounts[$k]=0};$keyCounts[$k]++}
    $lastExact=$null
    # Articles are opened and read one at a time. A window-pool/tear-off mode was implemented but
    # removed: WeChat keeps navigating a detached window to other articles, which silently attached the
    # wrong body to records (~50% loss). Pre-screening already cuts how many articles get opened, so the
    # pool bought nothing and risked correctness.
    # List-only mode: emit every candidate from the result list without opening a single article. The
    # caller pre-screens on title/account/snippet first, so we only pay to open what survives.
    if($listOnly){
        $listOut=@()
        foreach($candidate in $script:Candidates){
            $script:Processed++
            $m=Get-WindowMembership $candidate $cutoff $reference
            if($m -eq $false){continue}
            $listOut+=@{title=$candidate.title;account=$candidate.account;relative_date=$candidate.relative_date;age_seconds=$candidate.age_seconds;index=$candidate.index;snippet=$candidate.snippet;query=$request.keyword;identity='list:'+(Get-StableKey $candidate.title $candidate.account);within_window=$m;list_only=$true}
        }
        $script:Records=$listOut
        # A bare `return` here left the job stuck in `running`: the manager then saw a worker that
        # exited without a terminal status, and pass 2 never got a list. Persist the terminal state
        # before leaving, exactly like the full-collection path does.
        $script:Status=if($script:Boundary -or $script:Exhausted){'complete'}else{'partial'}
        $script:StopReason=if($script:Boundary){'TIME_WINDOW_BOUNDARY_REACHED'}elseif($script:Exhausted){'SEARCH_EXHAUSTED'}else{'SEARCH_INCOMPLETE'}
        $script:Phase='finished'
        Publish-State
        return
    }
    # When the caller already pre-screened the list, only the surviving keys are opened.
    # An EMPTY open_keys array is meaningful: it means the model rejected every candidate, so nothing
    # may be opened. PowerShell treats @() as false, so test for null instead of truthiness —
    # otherwise a fully-rejected query opened all of its candidates (31 articles on 具身智能).
    $openKeys=$null
    if($null -ne $request.open_keys){
        $openKeys=@{}
        foreach($k in @($request.open_keys)){$openKeys[[string]$k]=$true}
    }
    foreach($candidate in $script:Candidates){
        Check-Stop;$script:Processed++;$key=(Normalize-Text $candidate.title)+'|'+(Normalize-Text $candidate.account)
        if($null -ne $openKeys -and !$openKeys.ContainsKey($key)){continue}
        if($candidate.index -lt 0 -and $cached.ContainsKey($key) -and $keyCounts[$key] -eq 1 -and (!$includeBody -or $cached[$key].body_complete)){continue}
        # WeChat labels non-article rows (mini-program, 视频号) in the account field itself. Opening one
        # raises an app surface that may hold consent buttons, so skip before any click.
        if($candidate.account -match '小程序|视频号|公众号名片'){
            $script:Skipped+=@{title=$candidate.title;account=$candidate.account;index=$candidate.index;reason='NON_ARTICLE_ACCOUNT'}
            continue
        }
        # Current candidates are opened even on resume: title/account alone cannot prove article identity.
        $success=$false;$failure='';$article=$null
        for($attempt=0;$attempt -le $maxRetries;$attempt++){
            Check-Stop
            try{
                $search=Find-Search;if(!$search){throw 'SEARCH_WINDOW_LOST'}
                $actual=(Element-Id $search.root 'weixin-search-input').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value;if($actual -cne $request.keyword){throw 'QUERY_CHANGED'}
                $items=Search-Items $search;$e=$null
                if($candidate.index -ge 0 -and $candidate.index -lt $items.Count -and (Normalize-Text $items[$candidate.index].Current.Name) -ceq (Normalize-Text $candidate.title)){$e=$items[$candidate.index]}
                if(!$e){throw 'SEARCH_INDEX_CHANGED'}
                $article=Open-Candidate $search $e $candidate $reference
                $record=$article.record;$record.url=Read-PublicUrl $article.window;$record.identity=Get-ArticleIdentity $record.url;$record.captured_at=[datetimeoffset]::Now.ToString('o');$record.source='logged-in WeChat desktop';$record.query=$request.keyword
                if($record.published_at_iso){$dt=[datetimeoffset]::Parse($record.published_at_iso);if($lastExact -and $dt -gt $lastExact){$script:OrderingIssues+=@{type='exact_date_inversion';index=$candidate.index}};$lastExact=$dt}
                $membership=Get-WindowMembership $record $cutoff $reference
                # The window is still the active one: the next click would navigate it elsewhere, so read
                # and close it now and the body cannot be swapped underneath the record.
                $single=New-Object System.Collections.ArrayList
                [void]$single.Add(@{window=$article.window;record=$record;candidate=$candidate;key=$key;membership=$membership})
                Read-Opened-Batch $single $cutoff $reference $includeBody $runtimeRoot ([ref]$cached)
                $success=$true
                break
            }catch{
                $failure=$_.Exception.Message
                if($failure -match 'CANCELLED|TIME_BUDGET|DESKTOP_LOCKED|CHALLENGE|QUERY_CHANGED|SORT_CHANGED|FOCUS_UNAVAILABLE|FOCUS_CHANGED'){throw}
                # A row or surface proven not to be an article must never be clicked again: stop this
                # candidate instead of retrying, so nothing can interact with a mini-program page.
                if($failure -match '^NON_ARTICLE_(RESULT|SURFACE)$'){$script:Skipped+=@{title=$candidate.title;account=$candidate.account;index=$candidate.index;reason=$failure};break}
                if($article){Close-OwnedArticle $article.window};Desktop-Pause 500
            }
        }
        if(!$success){$script:Errors+=@{title=$candidate.title;account=$candidate.account;index=$candidate.index;reason=$failure}}
        Publish-State;Desktop-Pause $delayMs
    }
    $uncertainDates=@($script:Records|Where-Object{$null -eq (Get-WindowMembership $_ $cutoff $reference)})
    $bodyIncompleteFinal=@($script:Records|Where-Object{$includeBody -and (Get-WindowMembership $_ $cutoff $reference) -eq $true -and !$_.body_complete})
    if($script:Errors.Count -or $script:OrderingIssues.Count -or $uncertainDates.Count -or $bodyIncompleteFinal.Count){$script:Status='partial';$script:StopReason=if($script:Errors.Count){'ARTICLE_EXTRACTION_ERRORS'}elseif($script:OrderingIssues.Count){'RESULT_ORDERING_UNCERTAINTY'}elseif($uncertainDates.Count){'PUBLICATION_DATE_PRECISION_UNCERTAIN'}else{'ARTICLE_BODY_INCOMPLETE'}}else{$script:Status='complete';$script:StopReason=if($script:Boundary){'TIME_WINDOW_BOUNDARY_REACHED'}else{'SEARCH_EXHAUSTED'}}
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
