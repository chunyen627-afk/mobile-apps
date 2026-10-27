# UI Automation worker for desk_remote_helper.py: one long-lived PowerShell process that reads one
# JSON command per line on stdin and answers one JSON line on stdout.
# ASCII only: every UI string (button names and so on) arrives in the commands, and both
# directions escape non-ASCII characters as \uXXXX, so console code pages never matter.
# It only touches the Claude and Codex desktop windows, and before any keystroke it checks that
# the right window is in the foreground and that the expected conversation is open.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DeskWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
"@
$AE = [System.Windows.Automation.AutomationElement]
$Tree = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function Out-Json($obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 6
  $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}

function Fail($code, $message) { throw "DESK:$code`:$message" }

function Find-Window($app) {
  foreach ($w in $AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    try { $p = Get-Process -Id $w.Current.ProcessId -ErrorAction Stop } catch { continue }
    $path = "$($p.Path)".ToLower()
    if ($app -eq 'claude' -and $path -like '*\windowsapps\claude_*\claude.exe' -and $w.Current.Name -eq 'Claude') { return $w }
    if ($app -eq 'codex' -and $p.ProcessName -eq 'ChatGPT') { return $w }
  }
  return $null
}

function Need-Window($app) {
  $w = Find-Window $app
  if (-not $w) { Fail 'app-not-running' 'window not found' }
  return $w
}

function Get-Docs($w) {
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'RootWebArea')
  return @($w.FindAll($Tree::Descendants, $cond) | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
}

function Find-ByName($root, $type, $name) {
  $cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)))
  return $root.FindFirst($Tree::Descendants, $cond)
}

# The one page whose title is $doc; with no title, the window itself.
function Need-Doc($w, $doc) {
  if (-not $doc) { return $w }
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'RootWebArea')
  $hits = @($w.FindAll($Tree::Descendants, $cond) | Where-Object { $_.Current.Name -eq $doc })
  if ($hits.Count -ne 1) { Fail 'title-mismatch' ("open: " + ((Get-Docs $w) -join ' | ')) }
  return $hits[0]
}

# Text in a message box, when the box exposes it; $null when it cannot be read.
function Box-Text($edit) {
  $p = $null
  if ($edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { return $p.Current.Value }
  if ($edit.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$p)) { return $p.DocumentRange.GetText(20000) }
  return $null
}

function Same-Element($a, $b) {
  return [System.Windows.Automation.Automation]::Compare($a.GetRuntimeId(), $b.GetRuntimeId())
}

function Invoke-Element($e) {
  $p = $null
  if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return $true }
  return $false
}

# The permission block: the container around the deny button, with its texts and buttons.
function Get-Prompt($w, $s) {
  $deny = Find-ByName $w $CT::Button $s.deny
  if (-not $deny) { return $null }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $box = $deny
  for ($i = 0; $i -lt 5; $i++) {
    $parent = $walker.GetParent($box)
    if (-not $parent) { break }
    $box = $parent
    $texts = @($box.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
      ForEach-Object { $_.Current.Name.Trim() } | Where-Object { $_ })
    if ($texts.Count -ge 1) { break }
  }
  $buttons = @($box.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button))) |
    ForEach-Object { $_.Current.Name } | Where-Object { $_ })
  return @{ text = ($texts -join "`n"); buttons = $buttons }
}

# No Alt-key trick here: a lone Alt opens the Electron apps' menu bar, which then swallowed the
# paste and the click (found live). Opening the conversation link already brings the app up.
function Bring-Front($w) {
  $hwnd = [IntPtr]$w.Current.NativeWindowHandle
  if ([DeskWin]::GetForegroundWindow() -eq $hwnd) { return }
  if ([DeskWin]::IsIconic($hwnd)) { [DeskWin]::ShowWindow($hwnd, 9) | Out-Null }  # SW_RESTORE
  [DeskWin]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 300
  if ([DeskWin]::GetForegroundWindow() -ne $hwnd) { Fail 'focus-failed' 'could not bring the window to the front' }
}

function Save-Clipboard {
  $saved = @{}
  $data = [System.Windows.Forms.Clipboard]::GetDataObject()
  if (-not $data) { return $saved }
  $kept = @('UnicodeText', 'Text', 'Rich Text Format', 'HTML Format', 'Bitmap', 'FileDrop')
  $formats = @($data.GetFormats($false))
  foreach ($f in $formats) {
    if ($kept -contains $f) { $saved[$f] = $data.GetData($f) }
  }
  $saved['__unsafe'] = ($formats.Count -gt 0 -and $saved.Count -eq 0)
  return $saved
}

function Restore-Clipboard($saved) {
  $obj = New-Object System.Windows.Forms.DataObject
  $any = $false
  foreach ($k in $saved.Keys) {
    if ($k -ne '__unsafe' -and $null -ne $saved[$k]) { $obj.SetData($k, $saved[$k]); $any = $true }
  }
  if ($any) { [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true) } else { [System.Windows.Forms.Clipboard]::Clear() }
}

# Text plus the formats that keep it out of clipboard history and cloud clipboard.
function Set-PrivateText($text) {
  $obj = New-Object System.Windows.Forms.DataObject
  $obj.SetData('UnicodeText', $text)
  $obj.SetData('ExcludeClipboardContentFromMonitorProcessing', (New-Object System.IO.MemoryStream (, [byte[]](0))))
  $obj.SetData('CanIncludeInClipboardHistory', (New-Object System.IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
  $obj.SetData('CanUploadToCloudClipboard', (New-Object System.IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
  [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true)
}

# Pastes into the message box of $scope (the expected page) and presses Enter only after the box
# reads back the pasted text, when it can be read at all. A box found elsewhere in the window
# (a page still being replaced after a switch) is never used.
function Paste-Send($w, $scope, $editName, $text) {
  $edit = Find-ByName $scope $CT::Edit $editName
  if (-not $edit) { Fail 'no-prompt-box' 'the message box is not on screen (a question may be pending)' }
  $saved = Save-Clipboard
  if ($saved['__unsafe']) { Fail 'clipboard-unsafe' 'the clipboard holds data that cannot be restored' }
  $before = [DeskWin]::GetForegroundWindow()
  $probe = (($text -replace '\s', '')).Substring(0, [Math]::Min(12, ($text -replace '\s', '').Length))
  try {
    Bring-Front $w
    $edit.SetFocus()
    Start-Sleep -Milliseconds 300
    if (-not $edit.Current.HasKeyboardFocus) { Fail 'focus-failed' 'the message box did not take focus' }
    # An empty Codex box reads back its placeholder, which is also its name (found live 10/27).
    $already = Box-Text $edit
    if ($already -and $already.Trim() -and $already.Trim() -ne $editName.Trim()) {
      Fail 'box-not-empty' 'the message box already holds unsent text'
    }
    Set-PrivateText $text
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 500
    if ([DeskWin]::GetForegroundWindow() -ne [IntPtr]$w.Current.NativeWindowHandle) { Fail 'focus-failed' 'focus moved before sending' }
    # The page reports the box's text a little later than it shows it: read for up to 2 s.
    $now = $null
    for ($i = 0; $i -lt 8; $i++) {
      $now = Box-Text $edit
      if ($null -eq $now -or ($now -replace '\s', '').Contains($probe)) { break }
      Start-Sleep -Milliseconds 250
    }
    if ($null -ne $now -and -not (($now -replace '\s', '').Contains($probe))) {
      [System.Windows.Forms.SendKeys]::SendWait('^a{DEL}')
      $seen = ($now -replace '\s', ' ')
      Fail 'paste-failed' ("the box reads " + $seen.Length + " chars: " + $seen.Substring(0, [Math]::Min(30, $seen.Length)))
    }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 300
  } finally {
    Restore-Clipboard $saved
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

function Menu-Item($w, $name) {
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 250
    $item = Find-ByName $w $CT::MenuItem $name
    if ($item) { return $item }
  }
  return $null
}

# Claude keeps "allow once" in a dropdown that only a real click opens (its ExpandCollapse
# reports success without opening, Invoke is missing, and keys were not reliable). One click
# on the dropdown's centre, only when Claude's window is the top window at that point (Chromium
# reports only unnamed groups there, so the element itself cannot be checked); then the menu
# item is invoked.
# One real click on the centre of $e, only when $w (or a popup of the same app, such as a menu)
# is the top window at that point.
function Click-Element($w, $e, $what) {
  $r = $e.Current.BoundingRectangle
  if ($r.IsEmpty -or $r.Width -lt 2) { Fail 'menu-failed' "$what has no position on screen" }
  $pt = New-Object DeskWin+POINT
  $pt.X = [int]($r.X + $r.Width / 2); $pt.Y = [int]($r.Y + $r.Height / 2)
  $top = [DeskWin]::GetAncestor([DeskWin]::WindowFromPoint($pt), 2)  # GA_ROOT
  if ($top -ne [IntPtr]$w.Current.NativeWindowHandle) {
    $owner = [uint32]0
    $null = [DeskWin]::GetWindowThreadProcessId($top, [ref]$owner)
    if ($owner -ne [uint32]$w.Current.ProcessId) { Fail 'focus-failed' "another window covers $what" }
  }
  [DeskWin]::SetCursorPos($pt.X, $pt.Y) | Out-Null
  [DeskWin]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [DeskWin]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

# Claude 3.6556 shows "allow once" as a button of its own (checked live 10/27); earlier builds
# kept it in the "more allow options" dropdown. Prefer the button: Invoke, else one checked click.
# Without it, open the dropdown with one checked click and invoke its menu item.
function Prompt-Gone($w, $s, $seconds) {
  for ($i = 0; $i -lt ($seconds * 4); $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Find-ByName $w $CT::Button $s.deny)) { return $true }
  }
  return $false
}

function Claude-AllowOnce($w, $s) {
  $direct = Find-ByName $w $CT::Button $s.allow_once
  # Invoke can report success without doing anything (found live 10/27): only a question that
  # goes away counts; otherwise fall through to one checked click.
  if ($direct -and (Invoke-Element $direct) -and (Prompt-Gone $w $s 3)) { return 'invoke' }
  $direct = Find-ByName $w $CT::Button $s.allow_once
  $more = Find-ByName $w $CT::Button $s.more_allow
  if (-not $direct -and -not $more) { Fail 'prompt-changed' 'no allow button is on screen' }
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  $how = $null
  try {
    Bring-Front $w
    if ($direct) {
      Click-Element $w (Find-ByName $w $CT::Button $s.allow_once) 'the allow button'
      if (-not (Prompt-Gone $w $s 4)) { Fail 'still-asking' 'the question is still on screen after the click' }
      return 'click'
    }
    Click-Element $w (Find-ByName $w $CT::Button $s.more_allow) 'the allow menu'
    if (Menu-Item $w $s.allow_once) { $how = 'menu click' }
    if (-not $how) {
      $menus = @($w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::MenuItem))) |
        ForEach-Object { $_.Current.Name })
      [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
      Fail 'menu-failed' ("the allow menu did not open; menu items: " + ($menus -join ' | ') + "; fg=" + ([DeskWin]::GetForegroundWindow() -eq [IntPtr]$w.Current.NativeWindowHandle))
    }
    $item = Menu-Item $w $s.allow_once
    if (-not (Invoke-Element $item)) { Fail 'menu-failed' 'allow once could not be invoked' }
    return $how
  } finally {
    [DeskWin]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

# The card of one option question: the Group whose name starts with the question's text
# (Claude 3.6556 puts the options, "other", "skip" and "submit" inside it; read live 10/27).
function Find-QuestionCard($scope, $question) {
  $prefix = ($question -replace '\s', '')
  $prefix = $prefix.Substring(0, [Math]::Min(15, $prefix.Length))
  $groups = $scope.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Group)))
  foreach ($g in $groups) {
    if (($g.Current.Name -replace '\s', '').StartsWith($prefix)) { return $g }
  }
  return $null
}

# An option button is named "<label> <description>" or just "<label>".
function Find-Option($card, $label) {
  $buttons = $card.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
  foreach ($b in $buttons) {
    $n = $b.Current.Name
    if ($n -eq $label -or $n.StartsWith("$label ")) { return $b }
  }
  return $null
}

function Is-On($button) {
  $p = $null
  if (-not $button.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { return $null }
  return ("" + $p.Current.ToggleState) -eq 'On'
}

function Wait-State($button, $want, $ms) {
  for ($i = 0; $i -lt ($ms / 150); $i++) {
    if ((Is-On $button) -eq $want) { return $true }
    Start-Sleep -Milliseconds 150
  }
  return (Is-On $button) -eq $want
}

function Scroll-To($e) {
  $p = $null
  if ($e.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) {
    $p.ScrollIntoView()
    Start-Sleep -Milliseconds 300
  }
}

# Turns a toggle on or off: Toggle() first, then one checked click on the element after it has
# been scrolled into view (a click from a stale position once turned on the wrong option, 10/27).
function Set-Toggle($w, $button, $want) {
  if ($null -eq (Is-On $button)) { Fail 'not-invokable' 'option has no toggle' }
  if ((Is-On $button) -eq $want) { return 'already' }
  Scroll-To $button
  $p = $null
  $null = $button.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)
  $p.Toggle()
  if (Wait-State $button $want 1000) { return 'toggle' }
  Scroll-To $button
  Click-Element $w $button 'an option'
  if (Wait-State $button $want 1500) { return 'click' }
  Fail 'toggle-failed' 'the option did not change'
}

function Set-On($w, $button) { return Set-Toggle $w $button $true }

# The option buttons of a card (every toggle except "other").
function Card-Options($card, $s) {
  $buttons = $card.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
  return @($buttons | Where-Object { $_.Current.Name -ne $s.other -and $null -ne (Is-On $_) })
}

# Exactly the chosen options are on (others switched off), or the answer is not sent.
function Make-Exact($w, $card, $s, $labels) {
  $hows = @()
  foreach ($label in $labels) {
    $option = Find-Option $card $label
    if (-not $option) { Fail 'not-found' 'option not on screen' }
    $hows += Set-Toggle $w $option $true
  }
  foreach ($b in (Card-Options $card $s)) {
    $n = $b.Current.Name
    $chosen = @($labels | Where-Object { $n -eq $_ -or $n.StartsWith("$_ ") }).Count -gt 0
    if (-not $chosen -and (Is-On $b)) { $hows += ('off:' + (Set-Toggle $w $b $false)) }
  }
  foreach ($b in (Card-Options $card $s)) {
    $n = $b.Current.Name
    $chosen = @($labels | Where-Object { $n -eq $_ -or $n.StartsWith("$_ ") }).Count -gt 0
    if ((Is-On $b) -ne $chosen) { Fail 'toggle-failed' 'the options on screen do not match the choice' }
  }
  return $hows
}

function Answer-Questions($w, $page, $s, $questions) {
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  $hows = @()
  try {
    Bring-Front $w
    $count = @($questions).Count
    for ($qi = 0; $qi -lt $count; $qi++) {
      $q = @($questions)[$qi]
      # Several questions are shown one page at a time ("next" between them, "submit" last).
      $card = $null
      for ($i = 0; $i -lt 12 -and -not $card; $i++) {
        $card = Find-QuestionCard $page $q.question
        if (-not $card) { Start-Sleep -Milliseconds 250 }
      }
      if (-not $card) { Fail 'question-changed' 'the question is not on screen' }
      $labels = @(@($q.labels) | Where-Object { $_ })
      $hows += Make-Exact $w $card $s $labels
      if ($q.other) {
        $hows += Set-On $w (Find-Option $card $s.other)
        Start-Sleep -Milliseconds 300
        $edit = $card.FindFirst($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)))
        if (-not $edit) { Fail 'not-found' 'no text box after choosing other' }
        Paste-Text $w $edit $q.other
      }
      $name = if ($qi -eq $count - 1) { $s.submit } else { $s.next }
      $button = Find-ByName $card $CT::Button $name
      if (-not $button) { Fail 'not-found' "no '$name' button on the card" }
      Scroll-To $button
      if (-not (Invoke-Element $button)) { Fail 'not-invokable' 'the card button could not be pressed' }
      Start-Sleep -Milliseconds 600
    }
    return ($hows -join ',')
  } finally {
    [DeskWin]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

# Pastes into a text box without pressing Enter (the "other" answer), keeping the clipboard.
function Paste-Text($w, $edit, $text) {
  $saved = Save-Clipboard
  if ($saved['__unsafe']) { Fail 'clipboard-unsafe' 'the clipboard holds data that cannot be restored' }
  try {
    $edit.SetFocus()
    Start-Sleep -Milliseconds 250
    if ([DeskWin]::GetForegroundWindow() -ne [IntPtr]$w.Current.NativeWindowHandle) { Fail 'focus-failed' 'focus moved' }
    Set-PrivateText $text
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 400
  } finally {
    Restore-Clipboard $saved
  }
}

# The first button in $scope whose name starts with $prefix (the composer's model and usage
# buttons); $null without a prefix or a match.
function Prefixed-Button($scope, $prefix) {
  if (-not $prefix) { return $null }
  $buttons = $scope.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
  foreach ($b in $buttons) { if ($b.Current.Name.StartsWith($prefix)) { return $b } }
  return $null
}

# The model button names the model, then the effort: "<prefix>Opus 5.5 <effort>".
function Shows-Model($button, $s, $label) {
  $rest = $button.Current.Name.Substring($s.model_prefix.Length).Trim()
  return ($rest -eq $label -or $rest.StartsWith("$label "))
}

# Elements named $name in the app's window or in its other top-level windows (menus may open in
# a popup window of their own).
function Find-InApp($w, $type, $name) {
  $hit = Find-ByName $w $type $name
  if ($hit) { return $hit }
  foreach ($other in $AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($other.Current.ProcessId -eq $w.Current.ProcessId -and -not (Same-Element $other $w)) {
      $hit = Find-ByName $other $type $name
      if ($hit) { return $hit }
    }
  }
  return $null
}

function Radio-Names($w) {
  return @($w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::RadioButton))) |
    ForEach-Object { $_.Current.Name })
}

# Picks $label in the model menu of the conversation $page: one checked click opens the menu
# (read live 10/27: models are radio buttons there), the radio is selected (Select, else one
# checked click), and only a model button that then names $label counts.
function Set-Model($w, $page, $s, $label) {
  $button = Prefixed-Button $page $s.model_prefix
  if (-not $button) { $button = Prefixed-Button $w $s.model_prefix }
  if (-not $button) { Fail 'not-found' 'no model button on screen' }
  if (Shows-Model $button $s $label) { return 'already' }
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  try {
    Bring-Front $w
    Click-Element $w $button 'the model button'
    $radio = $null
    for ($i = 0; $i -lt 12 -and -not $radio; $i++) {
      Start-Sleep -Milliseconds 250
      $radio = Find-InApp $w $CT::RadioButton $label
    }
    if (-not $radio) {
      $seen = (Radio-Names $w) -join ' | '
      [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
      Fail 'model-failed' ("the model is not in the menu; radio buttons: " + $seen)
    }
    $how = 'select'
    $p = $null
    if ($radio.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select() }
    else { $how = 'none' }
    for ($i = 0; $i -lt 6; $i++) {
      Start-Sleep -Milliseconds 250
      $now = Prefixed-Button $w $s.model_prefix
      if ($now -and (Shows-Model $now $s $label)) { return $how }
    }
    $radio = Find-InApp $w $CT::RadioButton $label
    if ($radio) {
      Click-Element $w $radio 'the model choice'
      $how = 'click'
      for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 250
        $now = Prefixed-Button $w $s.model_prefix
        if ($now -and (Shows-Model $now $s $label)) { return $how }
      }
    }
    if (Find-InApp $w $CT::RadioButton $label) { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') }
    Fail 'model-failed' 'the model button does not show the chosen model'
  } finally {
    # A menu left open would swallow the next keystrokes.
    Start-Sleep -Milliseconds 200
    if (Find-InApp $w $CT::RadioButton $label) { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') }
    [DeskWin]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

function Run-Command($c) {
  $s = $c.strings
  switch ($c.cmd) {
    'ping' { return @{ ok = $true } }
    'inspect' {
      $w = Find-Window $c.app
      if (-not $w) { return @{ ok = $true; window = $false } }
      $prompt = Get-Prompt $w $s
      $edit = Find-ByName $w $CT::Edit $s.edit
      # The composer's model and usage buttons, in one pass over the buttons (Claude only).
      $model = $null; $usage = $null
      if ($s.model_prefix -or $s.usage_prefix) {
        $buttons = $w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
        foreach ($b in $buttons) {
          $n = $b.Current.Name
          if (-not $model -and $s.model_prefix -and $n.StartsWith($s.model_prefix)) { $model = $n }
          if (-not $usage -and $s.usage_prefix -and $n.StartsWith($s.usage_prefix)) { $usage = $n }
        }
      }
      return @{ ok = $true; window = $true; docs = @(Get-Docs $w); edit = [bool]$edit; prompt = $prompt
        model = $model; usage = $usage }
    }
    'model' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      return @{ ok = $true; how = (Set-Model $w $page $s $c.model) }
    }
    'docs' {
      $w = Find-Window $c.app
      if (-not $w) { return @{ ok = $true; window = $false; docs = @() } }
      return @{ ok = $true; window = $true; docs = @(Get-Docs $w) }
    }
    'invoke' {
      $w = Need-Window $c.app
      $null = Need-Doc $w $c.doc
      $b = Find-ByName $w $CT::Button $c.name
      if (-not $b) { Fail 'not-found' "button not found" }
      if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'button has no invoke pattern' }
      return @{ ok = $true }
    }
    'send' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      Paste-Send $w $page $s.edit $c.text
      return @{ ok = $true }
    }
    'new_send' {
      $w = Need-Window $c.app
      $before = @(Get-Docs $w)
      $b = Find-ByName $w $CT::Button $c.name
      if (-not $b) { Fail 'not-found' 'new conversation button not found' }
      if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'new conversation button has no invoke pattern' }
      $changed = $false
      for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        $now = @(Get-Docs $w)
        if (($now -join '|') -ne ($before -join '|')) { $changed = $true; break }
      }
      if (-not $changed) { Fail 'title-mismatch' 'the new conversation did not open' }
      Start-Sleep -Milliseconds 1500
      Paste-Send $w $w $s.edit $c.text
      return @{ ok = $true; docs = @(Get-Docs $w) }
    }
    'answer' {
      $w = Need-Window $c.app
      $null = Need-Doc $w $c.doc
      $prompt = Get-Prompt $w $s
      if (-not $prompt -or $prompt.text -ne $c.expect) { Fail 'prompt-changed' 'the question on screen changed' }
      if ($c.decision -eq 'deny') {
        $b = Find-ByName $w $CT::Button $s.deny
        if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'deny has no invoke pattern' }
        return @{ ok = $true; how = 'invoke' }
      }
      if ($c.app -eq 'codex') {
        $b = Find-ByName $w $CT::Button $s.allow_once
        if (-not $b -or -not (Invoke-Element $b)) { Fail 'not-invokable' 'allow once not invokable' }
        return @{ ok = $true; how = 'invoke' }
      }
      return @{ ok = $true; how = (Claude-AllowOnce $w $s) }
    }
    'choose' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      return @{ ok = $true; how = (Answer-Questions $w $page $s @($c.questions)) }
    }
    default { Fail 'bad-command' "unknown command" }
  }
}

[Console]::InputEncoding = [Text.Encoding]::ASCII
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  if (-not $line.Trim()) { continue }
  try {
    $c = $line | ConvertFrom-Json
    Out-Json (Run-Command $c)
  } catch {
    $m = "$($_.Exception.Message)"
    if ($m -match '^DESK:([a-z-]+):(.*)$') { Out-Json @{ ok = $false; error = $Matches[1]; message = $Matches[2] } }
    else { Out-Json @{ ok = $false; error = 'worker-error'; message = $m } }
  }
}
