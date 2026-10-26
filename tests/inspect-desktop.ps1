$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'collector\Core.ps1')
function Check-Stop{}
. (Join-Path $root 'collector\Desktop.ps1')
Get-MainWindow|Out-Null
foreach($w in Browser-Windows){Write-Output "WINDOW=$($w.handle) TITLE=$($w.document.Current.Name)";$hasTitle=!!(Element-Id $w.root 'activity-name');$hasShare=!!(Element-Id $w.root 'js_text_desc');Write-Output "ARTICLE_HEADER=$hasTitle SHARE=$hasShare";if(!$hasTitle -and !$hasShare){$t=$w.document.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(3000);Write-Output $t}}
