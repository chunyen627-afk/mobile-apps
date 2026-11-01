# Read-only: lists the named controls of the Claude or Codex desktop window (buttons, menu
# items, radio buttons, check boxes, edit boxes, short texts) with their UI Automation patterns,
# into a UTF-8 file. It clicks nothing and sends no keys. Use it after a desktop app update to
# find renamed controls and fix ui_strings.json. Open a menu by hand first to list its items.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\uia_scan.ps1 -App claude -Out scan.txt
param([ValidateSet('claude', 'codex')][string]$App = 'claude', [string]$Out = 'uia_scan.txt')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Tree = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$wanted = @($CT::Button, $CT::MenuItem, $CT::RadioButton, $CT::CheckBox, $CT::Edit, $CT::Menu, $CT::Text, $CT::Document)
$lines = New-Object System.Collections.Generic.List[string]
foreach ($w in $AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
  try { $p = Get-Process -Id $w.Current.ProcessId -ErrorAction Stop } catch { continue }
  $isClaude = "$($p.Path)".ToLower() -like '*\windowsapps\claude_*\claude.exe'
  $isCodex = $p.ProcessName -eq 'ChatGPT'
  if (($App -eq 'claude' -and -not $isClaude) -or ($App -eq 'codex' -and -not $isCodex)) { continue }
  $lines.Add('WINDOW ' + $w.Current.Name + ' minimized=' + ($w.Current.BoundingRectangle.IsEmpty))
  foreach ($e in $w.FindAll($Tree::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    $c = $e.Current
    if (-not $c.Name -or $wanted -notcontains $c.ControlType) { continue }
    if ($c.ControlType -eq $CT::Text -and $c.Name.Length -gt 60) { continue }
    $patterns = ($e.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers.Pattern', '' }) -join ','
    $lines.Add(('  {0} | {1} | id={2} | {{{3}}}' -f ($c.ControlType.ProgrammaticName -replace 'ControlType\.', ''), $c.Name, $c.AutomationId, $patterns))
  }
}
[IO.File]::WriteAllLines($Out, $lines, (New-Object System.Text.UTF8Encoding $false))
"wrote $($lines.Count) lines to $Out"
