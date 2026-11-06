# uia-smoke.ps1: clicks the lyric-access smoke window's button through UI Automation, the way a
# Windows screen reader does (docs/67 G10, issue #8489).  scripts/ci/windows-graphics-e2e.sh starts
# `access-smoke --wait-click <s>` and runs this beside it; the smoke program exits 0 once the click
# request reaches it through AccessKit's UI Automation adapter.
#
# Checks that the window's UI Automation tree is AccessKit's (a button named "Press me" with the
# Invoke pattern under the window) and invokes it.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ci/uia-smoke.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$title = 'Lyric Access Smoke'

function Find-Within($parent, $scope, $condition, $seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $found = $parent.FindFirst($scope, $condition)
    if ($null -ne $found) { return $found }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $null
}

$byTitle = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)
$window = Find-Within $AE::RootElement $Scope::Children $byTitle 30
if ($null -eq $window) { throw "no top-level window named '$title'" }
Write-Output ("uia: window '{0}' ({1})" -f $window.Current.Name, $window.Current.ControlType.ProgrammaticName)

$byName = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Press me')
$isButton = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$condition = New-Object System.Windows.Automation.AndCondition($byName, $isButton)
$button = Find-Within $window $Scope::Descendants $condition 15
if ($null -eq $button) {
  $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $child = $walker.GetFirstChild($window)
  while ($null -ne $child) {
    Write-Output ("uia:   {0} '{1}'" -f $child.Current.ControlType.ProgrammaticName, $child.Current.Name)
    $child = $walker.GetNextSibling($child)
  }
  throw "no button named 'Press me' under the window"
}
Write-Output ("uia: button '{0}'" -f $button.Current.Name)

$invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$invoke.Invoke()
Write-Output 'uia: invoked the button'
