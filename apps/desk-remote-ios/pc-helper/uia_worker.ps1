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

function Need-Doc($w, $doc) {
  if (-not $doc) { return }
  $names = Get-Docs $w
  $hits = @($names | Where-Object { $_ -eq $doc })
  if ($hits.Count -ne 1) { Fail 'title-mismatch' ("open: " + ($names -join ' | ')) }
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

function Bring-Front($w) {
  $hwnd = [IntPtr]$w.Current.NativeWindowHandle
  if ([DeskWin]::IsIconic($hwnd)) { [DeskWin]::ShowWindow($hwnd, 9) | Out-Null }  # SW_RESTORE
  # A tap of Alt lets this background process move the foreground window.
  [DeskWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  [DeskWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  [DeskWin]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 250
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

function Paste-Send($w, $editName, $text) {
  $edit = Find-ByName $w $CT::Edit $editName
  if (-not $edit) { Fail 'no-prompt-box' 'the message box is not on screen (a question may be pending)' }
  $saved = Save-Clipboard
  if ($saved['__unsafe']) { Fail 'clipboard-unsafe' 'the clipboard holds data that cannot be restored' }
  $before = [DeskWin]::GetForegroundWindow()
  try {
    Bring-Front $w
    $edit.SetFocus()
    Start-Sleep -Milliseconds 300
    if (-not $edit.Current.HasKeyboardFocus) { Fail 'focus-failed' 'the message box did not take focus' }
    Set-PrivateText $text
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 500
    if ([DeskWin]::GetForegroundWindow() -ne [IntPtr]$w.Current.NativeWindowHandle) { Fail 'focus-failed' 'focus moved before sending' }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 300
  } finally {
    Restore-Clipboard $saved
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

function Menu-Item($w, $name) {
  for ($i = 0; $i -lt 8; $i++) {
    $item = Find-ByName $AE::RootElement $CT::MenuItem $name
    if ($item) { return $item }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

# Claude keeps "allow once" in a dropdown that ignores Invoke; open it by keyboard first and only
# then with one real click on the dropdown's centre, after checking what is under the pointer.
function Claude-AllowOnce($w, $s) {
  $more = Find-ByName $w $CT::Button $s.more_allow
  if (-not $more) { Fail 'prompt-changed' 'the allow menu is not on screen' }
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  $how = $null
  try {
    $p = $null
    if ($more.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) {
      $p.Expand(); if (Menu-Item $w $s.allow_once) { $how = 'expand' }
    }
    if (-not $how) {
      Bring-Front $w
      foreach ($key in @('{ENTER}', ' ', '%{DOWN}')) {
        $more.SetFocus(); Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait($key)
        if (Menu-Item $w $s.allow_once) { $how = "key $key"; break }
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
      }
    }
    if (-not $how) {
      $r = $more.Current.BoundingRectangle
      $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
      $hit = $AE::FromPoint((New-Object System.Windows.Point($x, $y)))
      $onTarget = $hit -and $hit.Current.Name -eq $s.more_allow
      if ($hit -and -not $onTarget) {
        $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($hit)
        $onTarget = $parent -and $parent.Current.Name -eq $s.more_allow
      }
      if (-not $onTarget) { Fail 'focus-failed' 'something covers the allow menu' }
      [DeskWin]::SetCursorPos($x, $y) | Out-Null
      [DeskWin]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [DeskWin]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
      if (Menu-Item $w $s.allow_once) { $how = 'click' }
    }
    if (-not $how) { Fail 'menu-failed' 'the allow menu did not open' }
    $item = Menu-Item $w $s.allow_once
    if (-not (Invoke-Element $item)) { Fail 'menu-failed' 'allow once could not be invoked' }
    return $how
  } finally {
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
      return @{ ok = $true; window = $true; docs = @(Get-Docs $w); edit = [bool]$edit; prompt = $prompt }
    }
    'docs' {
      $w = Find-Window $c.app
      if (-not $w) { return @{ ok = $true; window = $false; docs = @() } }
      return @{ ok = $true; window = $true; docs = @(Get-Docs $w) }
    }
    'invoke' {
      $w = Need-Window $c.app
      Need-Doc $w $c.doc
      $b = Find-ByName $w $CT::Button $c.name
      if (-not $b) { Fail 'not-found' "button not found" }
      if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'button has no invoke pattern' }
      return @{ ok = $true }
    }
    'send' {
      $w = Need-Window $c.app
      Need-Doc $w $c.doc
      Paste-Send $w $s.edit $c.text
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
      Start-Sleep -Milliseconds 500
      Paste-Send $w $s.edit $c.text
      return @{ ok = $true; docs = @(Get-Docs $w) }
    }
    'answer' {
      $w = Need-Window $c.app
      Need-Doc $w $c.doc
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
