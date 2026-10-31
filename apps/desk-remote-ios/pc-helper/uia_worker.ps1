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
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);
  // Hidden Chromium top-level windows of these processes with this title (closed to the tray).
  public static System.Collections.Generic.List<IntPtr> HiddenTitled(uint[] pids, string title) {
    var found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (Array.IndexOf(pids, pid) >= 0 && !IsWindowVisible(h)) {
        var c = new System.Text.StringBuilder(256); GetClassName(h, c, 256);
        var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
        if (c.ToString() == "Chrome_WidgetWin_1" && t.ToString() == title) found.Add(h);
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // A standard dialog's (#32770) buttons and texts are child windows that managed UI Automation
  // reports only as unnamed panes (a message box, 10/29): read them as windows instead.
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  public static System.Collections.Generic.List<IntPtr> Children(IntPtr parent, string cls) {
    var found = new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(parent, (h, l) => {
      var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() == cls && IsWindowVisible(h)) found.Add(h);
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // Visible standard dialogs, owned ones included: UI Automation lists a dialog owned by an app
  // window under that window, not on the desktop (Claude's "still working" question, 10/30).
  public static System.Collections.Generic.List<IntPtr> VisibleDialogs() {
    var found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, l) => {
      var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() == "#32770" && IsWindowVisible(h)) found.Add(h);
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string Text(IntPtr hWnd) {
    var t = new System.Text.StringBuilder(1024); GetWindowText(hWnd, t, 1024);
    return t.ToString().Replace("&", "").Trim();
  }
  // What a click on the dialog's button sends to the dialog: WM_COMMAND with BN_CLICKED.
  public static void Press(IntPtr button) {
    SendMessage(GetParent(button), 0x0111, (IntPtr)(GetDlgCtrlID(button) & 0xFFFF), button);
  }
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

# Claude closed to the tray still answers UI Automation (home PC, 10/28): enough to read its
# usage button, and nothing else is done with that window.
function Find-HiddenWindow($app) {
  if ($app -ne 'claude') { return $null }
  $pids = @(Get-Process claude -ErrorAction SilentlyContinue |
    Where-Object { "$($_.Path)".ToLower() -like '*\windowsapps\claude_*\claude.exe' } | ForEach-Object { [uint32]$_.Id })
  if (-not $pids) { return $null }
  foreach ($h in [DeskWin]::HiddenTitled([uint32[]]$pids, 'Claude')) {
    try { return $AE::FromHandle($h) } catch { }
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
  if ([DeskWin]::GetForegroundWindow() -eq $hwnd) { return }
  # Second try: share the input state of the window in front, which Windows then lets hand over
  # the foreground (sends no keys, so no Electron menu bar).
  $front = [DeskWin]::GetForegroundWindow()
  $owner = [uint32]0
  $thread = [DeskWin]::GetWindowThreadProcessId($front, [ref]$owner)
  $me = [DeskWin]::GetCurrentThreadId()
  if ($thread -and $thread -ne $me -and [DeskWin]::AttachThreadInput($me, $thread, $true)) {
    try {
      [DeskWin]::BringWindowToTop($hwnd) | Out-Null
      [DeskWin]::SetForegroundWindow($hwnd) | Out-Null
    } finally { [DeskWin]::AttachThreadInput($me, $thread, $false) | Out-Null }
    Start-Sleep -Milliseconds 300
    if ([DeskWin]::GetForegroundWindow() -eq $hwnd) { return }
  }
  # Name what is in front, so the phone can say what blocked it.
  $front = [DeskWin]::GetForegroundWindow()
  $owner = [uint32]0
  $null = [DeskWin]::GetWindowThreadProcessId($front, [ref]$owner)
  $name = 'none'
  if ($front -ne [IntPtr]::Zero) {
    $name = 'unknown'
    try { $name = (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { }
    if ($owner -eq [uint32]$w.Current.ProcessId) { $name = 'same-app' }
  }
  Fail 'focus-failed' "could not bring the window to the front; in front: $name"
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

# An image plus the same keep-it-private formats as Set-PrivateText.
function Set-PrivateImage($image) {
  $obj = New-Object System.Windows.Forms.DataObject
  $obj.SetImage($image)
  $obj.SetData('ExcludeClipboardContentFromMonitorProcessing', (New-Object System.IO.MemoryStream (, [byte[]](0))))
  $obj.SetData('CanIncludeInClipboardHistory', (New-Object System.IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
  $obj.SetData('CanUploadToCloudClipboard', (New-Object System.IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
  [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true)
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
function Paste-Send($w, $scope, $editName, $text, $imagePaths = @()) {
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
    $imagePaths = @($imagePaths | Where-Object { $_ })
    if ($imagePaths) {
      # Photos from the phone: each pasted as a bitmap first; the app attaches them to the message.
      Add-Type -AssemblyName System.Drawing
      foreach ($imagePath in $imagePaths) {
        $image = [System.Drawing.Image]::FromFile($imagePath)
        try { Set-PrivateImage $image } finally { $image.Dispose() }
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 1500
        if ([DeskWin]::GetForegroundWindow() -ne [IntPtr]$w.Current.NativeWindowHandle) { Fail 'focus-failed' 'focus moved after pasting the image' }
      }
      if (-not $text.Trim()) {
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 300
        return
      }
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

# "Other" is a toggle that shows a text box; its toggle state did not follow (live 10/27: a
# Toggle() then a click turned it off again), so the text box appearing is what counts.
function Card-Edit($card) {
  return $card.FindFirst($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)))
}

function Wait-Edit($card, $ms) {
  for ($i = 0; $i -lt ($ms / 200); $i++) {
    if (Card-Edit $card) { return $true }
    Start-Sleep -Milliseconds 200
  }
  return [bool](Card-Edit $card)
}

function Open-Other($w, $card, $s) {
  if (Card-Edit $card) { return 'other:open' }
  $other = Find-Option $card $s.other
  if (-not $other) { Fail 'not-found' 'no other option on the card' }
  Scroll-To $other
  $p = $null
  if ($other.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle() }
  if (Wait-Edit $card 1500) { return 'other:toggle' }
  Scroll-To $other
  Click-Element $w (Find-Option $card $s.other) 'the other option'
  if (Wait-Edit $card 2000) { return 'other:click' }
  Fail 'toggle-failed' 'no text box after choosing other'
}

# True once the question's card (or its button) has left the screen, within $ms.
function Card-Gone($page, $question, $button, $ms) {
  for ($i = 0; $i -lt ($ms / 250); $i++) {
    Start-Sleep -Milliseconds 250
    $card = Find-QuestionCard $page $question
    if (-not $card) { return $true }
    try { if ($button.Current.IsOffscreen -and -not (Find-ByName $card $CT::Button $button.Current.Name)) { return $true } } catch { return $true }
  }
  return $false
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
      # "Other" first: in a single-choice question it clears the chosen option itself, which
      # cannot be switched off on its own (live 10/27).
      if ($q.other) { $hows += Open-Other $w $card $s }
      $hows += Make-Exact $w $card $s $labels
      if ($q.other) {
        $edit = Card-Edit $card
        if (-not $edit) { Fail 'toggle-failed' 'the other text box went away' }
        Paste-Text $w $edit $q.other
      }
      $name = if ($qi -eq $count - 1) { $s.submit } else { $s.next }
      $button = Find-ByName $card $CT::Button $name
      if (-not $button) { Fail 'not-found' "no '$name' button on the card" }
      Scroll-To $button
      if (-not (Invoke-Element $button)) { Fail 'not-invokable' 'the card button could not be pressed' }
      # Claude 4.4212's card ignores the Invoke (the options toggled, the question stayed; phone
      # 10/31): when the button is still there after a moment, one real click on it.
      if (-not (Card-Gone $page $q.question $button 1500)) {
        Scroll-To $button
        Click-Element $w $button 'the card button'
        $hows += 'submit:click'
        $null = Card-Gone $page $q.question $button 1500
      } else {
        $hows += 'submit:invoke'
      }
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

# The model button names the model, then the effort: "<model_strip>Opus 5.5 <effort>" (Claude
# starts with a label to strip, Codex with the model itself).
function Shows-Model($button, $s, $label) {
  $rest = $button.Current.Name
  if ($s.model_strip -and $rest.StartsWith($s.model_strip)) { $rest = $rest.Substring($s.model_strip.Length) }
  $rest = $rest.Trim()
  return ($rest -eq $label -or $rest.StartsWith("$label "))
}

function Wait-Named($w, $type, $name, $tries) {
  for ($i = 0; $i -lt $tries; $i++) {
    $hit = Find-InApp $w $type $name
    if ($hit) { return $hit }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

# Collapses $name if it is expanded (Codex leaves its menus open after a pick).
function Collapse-Named($w, $name) {
  if (-not $name) { return }
  $e = Find-InApp $w $CT::Button $name
  $p = $null
  if ($e -and $e.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p) -and ("" + $p.Current.ExpandCollapseState) -eq 'Expanded') {
    $p.Collapse()
  }
}

# Codex: UI Automation only, no mouse or keys, works with the window minimized (read live 10/27):
# Expand the model button, Invoke "select model", Invoke the model's radio button, then the
# button must name it; menus left open are collapsed by their own buttons.
function Set-CodexModel($w, $page, $s, $label) {
  $button = Prefixed-Button $page $s.model_prefix
  if (-not $button) { $button = Prefixed-Button $w $s.model_prefix }
  if (-not $button) { Fail 'not-found' 'no model button on screen' }
  if (Shows-Model $button $s $label) { return 'already' }
  $p = $null
  if (-not $button.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { Fail 'not-invokable' 'the model button does not expand' }
  try {
    $p.Expand()
    $item = Wait-Named $w $CT::MenuItem $s.model_menu_item 12
    if (-not $item) { Fail 'model-failed' 'the model menu did not open' }
    if (-not (Invoke-Element $item)) { Fail 'not-invokable' 'the model item could not be pressed' }
    $radio = Wait-Named $w $CT::RadioButton $label 12
    if (-not $radio) { Fail 'model-failed' ("the model is not in the menu; radio buttons: " + ((Radio-Names $w) -join ' | ')) }
    if (-not (Invoke-Element $radio)) { Fail 'not-invokable' 'the model could not be chosen' }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 250
      $now = Prefixed-Button $w $s.model_prefix
      if ($now -and (Shows-Model $now $s $label)) { return 'invoke' }
    }
    Fail 'model-failed' 'the model button does not show the chosen model'
  } finally {
    Start-Sleep -Milliseconds 300
    Collapse-Named $w $s.effort_menu
    $again = Prefixed-Button $w $s.model_prefix
    if ($again) { $q = $null; if ($again.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$q) -and ("" + $q.Current.ExpandCollapseState) -eq 'Expanded') { $q.Collapse() } }
  }
}

# The app's own update button: Claude's starts with update_prefix and names the version
# ("restart to update v4.29.0"); Codex's is exactly update_prefix (update_exact).
function Is-UpdateButton($s, $n) {
  if (-not $s.update_prefix -or -not $n) { return $false }
  if ($s.update_exact) { return $n -eq $s.update_prefix }
  return $n.StartsWith($s.update_prefix)
}

# Codex's fast mode (the lightning toggle in the model menu, read from the app's own strings
# 10/29): the menu shows "enable fast mode" while it is off and "enable standard mode" while it
# is on, so the label that is there tells the state and pressing it switches. Of any control type.
function Set-CodexFast($w, $page, $s, $on) {
  if (-not $s.fast_on -or -not $s.fast_off) { Fail 'not-supported' 'no fast mode labels' }
  $button = Prefixed-Button $page $s.model_prefix
  if (-not $button) { $button = Prefixed-Button $w $s.model_prefix }
  if (-not $button) { Fail 'not-found' 'no model button on screen' }
  $p = $null
  if (-not $button.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { Fail 'not-invokable' 'the model button does not expand' }
  $want = if ($on) { $s.fast_off } else { $s.fast_on }
  $press = if ($on) { $s.fast_on } else { $s.fast_off }
  try {
    $p.Expand()
    $hit = $null
    for ($i = 0; $i -lt 12 -and -not $hit; $i++) {
      Start-Sleep -Milliseconds 250
      if (Find-AnyInApp $w $want) { return 'already' }
      $hit = Find-AnyInApp $w $press
    }
    if (-not $hit) { Fail 'fast-failed' ("no fast mode switch in the model menu; buttons: " + ((Button-Names $w) -join ' | ')) }
    if (-not (Invoke-Element $hit)) {
      $t = $null
      if ($hit.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$t)) { $t.Toggle() }
      else { Fail 'not-invokable' 'the fast mode switch could not be pressed' }
    }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 250
      if (Find-AnyInApp $w $want) { return 'invoke' }
    }
    # Some menus close on a pick: open it again to read the switch.
    if (-not (Find-AnyInApp $w $press)) {
      $p.Expand()
      for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 250
        if (Find-AnyInApp $w $want) { return 'invoke' }
      }
    }
    Fail 'fast-failed' 'the switch does not show the new state'
  } finally {
    Start-Sleep -Milliseconds 300
    $again = Prefixed-Button $w $s.model_prefix
    if ($again) { $q = $null; if ($again.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$q) -and ("" + $q.Current.ExpandCollapseState) -eq 'Expanded') { $q.Collapse() } }
  }
}

function Button-Names($w) {
  return @($w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button))) |
    ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -First 40)
}

# An element of any type named $name in the app's windows.
function Find-AnyInApp($w, $name) {
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
  $hit = $w.FindFirst($Tree::Descendants, $cond)
  if ($hit) { return $hit }
  foreach ($other in $AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($other.Current.ProcessId -eq $w.Current.ProcessId -and -not (Same-Element $other $w)) {
      $hit = $other.FindFirst($Tree::Descendants, $cond)
      if ($hit) { return $hit }
    }
  }
  return $null
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

# Rests the cursor on the centre of $e (no click), only when $w or a popup of the same app is
# the top window there: Claude's effort submenu opens on hover only (read live 10/27).
function Hover-Element($w, $e, $what) {
  $r = $e.Current.BoundingRectangle
  if ($r.IsEmpty -or $r.Width -lt 2) { Fail 'menu-failed' "$what has no position on screen" }
  $pt = New-Object DeskWin+POINT
  $pt.X = [int]($r.X + $r.Width / 2); $pt.Y = [int]($r.Y + $r.Height / 2)
  $top = [DeskWin]::GetAncestor([DeskWin]::WindowFromPoint($pt), 2)
  $owner = [uint32]0
  $null = [DeskWin]::GetWindowThreadProcessId($top, [ref]$owner)
  if ($owner -ne [uint32]$w.Current.ProcessId) { Fail 'focus-failed' "another window covers $what" }
  [DeskWin]::SetCursorPos($pt.X, $pt.Y) | Out-Null
}

# The radio button (or menu item) named "<label>" or "<label> <description>" in the app's windows.
function Find-Labelled($w, $type, $label) {
  foreach ($win in $AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($win.Current.ProcessId -ne $w.Current.ProcessId) { continue }
    foreach ($e in $win.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)))) {
      $n = $e.Current.Name
      if ($n -eq $label -or $n.StartsWith("$label ")) { return $e }
    }
  }
  return $null
}

function Wait-Labelled($w, $type, $label, $tries) {
  for ($i = 0; $i -lt $tries; $i++) {
    $hit = Find-Labelled $w $type $label
    if ($hit) { return $hit }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

# Opens a menu button: its ExpandCollapse pattern first, else one checked click.
function Open-Menu($w, $button, $what) {
  $p = $null
  if ($button.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $p.Expand(); return }
  Click-Element $w $button $what
}

# Esc closes Claude's menus; only while Claude is the foreground window.
function Close-Claude-Menus($w) {
  for ($i = 0; $i -lt 2; $i++) {
    $open = $w.FindFirst($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Menu)))
    if (-not $open) { return }
    if ([DeskWin]::GetForegroundWindow() -ne [IntPtr]$w.Current.NativeWindowHandle) { return }
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 300
  }
}

# The model button ends with the effort: "<prefix>Opus 5.5 <effort>".
function Shows-Effort($button, $label) { return $button.Current.Name.EndsWith(" $label") }

# Claude's effort: model menu -> rest the cursor on the effort item -> its radio button.
function Set-Effort($w, $page, $s, $label) {
  $button = Prefixed-Button $page $s.model_prefix
  if (-not $button) { $button = Prefixed-Button $w $s.model_prefix }
  if (-not $button) { Fail 'not-found' 'no model button on screen' }
  if (Shows-Effort $button $label) { return 'already' }
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  try {
    Bring-Front $w
    Open-Menu $w $button 'the model button'
    $item = Wait-Labelled $w $CT::MenuItem $s.effort_item 12
    if (-not $item) { Fail 'model-failed' 'the effort item is not in the model menu' }
    Hover-Element $w $item 'the effort item'
    $radio = Wait-Labelled $w $CT::RadioButton $label 12
    if (-not $radio) { Fail 'model-failed' ("the effort is not in the menu; radio buttons: " + ((Radio-Names $w) -join ' | ')) }
    if (-not (Invoke-Element $radio)) { Fail 'not-invokable' 'the effort could not be chosen' }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 250
      $now = Prefixed-Button $w $s.model_prefix
      if ($now -and (Shows-Effort $now $label)) { return 'invoke' }
    }
    Fail 'model-failed' 'the model button does not show the chosen effort'
  } finally {
    Start-Sleep -Milliseconds 200
    Close-Claude-Menus $w
    [DeskWin]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

# Claude's permission mode button is named after the current mode.
function Mode-Button($scope, $s) {
  $buttons = $scope.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
  foreach ($b in $buttons) { if (@($s.modes) -contains $b.Current.Name) { return $b } }
  return $null
}

function Set-ClaudeMode($w, $page, $s, $label) {
  $button = Mode-Button $page $s
  if (-not $button) { $button = Mode-Button $w $s }
  if (-not $button) { Fail 'not-found' 'no permission mode button on screen' }
  if ($button.Current.Name -eq $label) { return 'already' }
  $before = [DeskWin]::GetForegroundWindow()
  $cursor = New-Object DeskWin+POINT
  [DeskWin]::GetCursorPos([ref]$cursor) | Out-Null
  try {
    Bring-Front $w
    Open-Menu $w $button 'the permission mode button'
    $radio = Wait-Labelled $w $CT::RadioButton $label 12
    if (-not $radio) { Fail 'model-failed' ("the mode is not in the menu; radio buttons: " + ((Radio-Names $w) -join ' | ')) }
    if (-not (Invoke-Element $radio)) { Fail 'not-invokable' 'the mode could not be chosen' }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 250
      $now = Mode-Button $w $s
      if ($now -and $now.Current.Name -eq $label) { return 'invoke' }
    }
    Fail 'model-failed' 'the permission mode button does not show the chosen mode'
  } finally {
    Start-Sleep -Milliseconds 200
    Close-Claude-Menus $w
    [DeskWin]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($before -ne [IntPtr]::Zero) { [DeskWin]::SetForegroundWindow($before) | Out-Null }
  }
}

# Codex: UI Automation only. Its permission button does not show the current mode, so a pick
# can only be checked by the next turn; 'invoke' means the menu item was pressed.
function Set-CodexMode($w, $page, $s, $label) {
  $button = Find-ByName $page $CT::Button $s.permission_button
  if (-not $button) { $button = Find-ByName $w $CT::Button $s.permission_button }
  if (-not $button) { Fail 'not-found' 'no permission button on screen' }
  $p = $null
  if (-not $button.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { Fail 'not-invokable' 'the permission button does not expand' }
  $p.Expand()
  $item = Wait-Labelled $w $CT::MenuItem $label 16
  if (-not $item) { Fail 'model-failed' 'the mode is not in the permission menu' }
  if (-not (Invoke-Element $item)) { Fail 'not-invokable' 'the mode could not be chosen' }
  Start-Sleep -Milliseconds 600
  return 'invoke'
}

# The stop button Claude shows while a turn runs, inside the conversation's page.
function Stop-Turn($w, $page, $s) {
  if (-not $s.stop) { Fail 'not-supported' 'no stop button name for this app' }
  $b = Find-ByName $page $CT::Button $s.stop
  if (-not $b) { $b = Find-ByName $w $CT::Button $s.stop }
  if (-not $b) { Fail 'not-running' 'no stop button: nothing is running' }
  if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'the stop button could not be pressed' }
  return 'invoke'
}

# The usage button expands to a card (Claude 4.x, read 10/28): the group named usage_card holds,
# per limit, a Text label, a Text with its reset time and a ProgressBar named like the label whose
# value is the percent. Expanding works through UI Automation alone, also on a window in the
# tray. A card someone opened stays open; one opened here is closed again.
function Read-UsageCard($w, $s) {
  $btn = $null
  foreach ($b in $w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))) {
    $n = $b.Current.Name
    if ($n -and $n.StartsWith($s.usage_prefix)) { $btn = $b; break }
  }
  if (-not $btn) { Fail 'not-found' 'usage button not found' }
  try { $ec = $btn.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern) } catch { Fail 'not-invokable' 'the usage button does not expand' }
  $opened = $false
  if ($ec.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ec.Expand(); $opened = $true }
  try {
    $group = $null
    for ($i = 0; $i -lt 12 -and -not $group; $i++) {
      $group = Find-ByName $w $CT::Group $s.usage_card
      if (-not $group) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $group) { Fail 'not-found' 'the usage card did not show' }
    $rows = @(); $texts = @()
    foreach ($e in $group.FindAll($Tree::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
      $type = $e.Current.ControlType
      if ($type -eq $CT::Text) { $texts += $e.Current.Name }
      elseif ($type -eq $CT::ProgressBar) {
        $value = $null
        try { $value = $e.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value } catch { }
        $label = $e.Current.Name
        $reset = @($texts | Where-Object { $_ -and $_ -ne $label }) | Select-Object -Last 1
        $rows += ,@{ label = $label; percent = $value; reset = $reset }
        $texts = @()
      }
    }
    return @{ rows = $rows; how = $(if ($opened) { 'expanded' } else { 'open' }) }
  } finally {
    if ($opened) { try { $ec.Collapse() } catch { } }
  }
}

# Windows that pop up and wait for an answer (a firewall question, a message box) and keep the
# desktop apps from coming to the front: shown, cannot be minimized (or a standard dialog), and
# have buttons. Main windows, the shell's own pop-ups and notifications are not listed.
$PageDialogApps = @('claude', 'ChatGPT')
$PopupSkip = @('ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost', 'TextInputHost', 'LockApp', 'cua-driver')

function Popup-Buttons($win) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $out = @()
  foreach ($b in $win.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))) {
    $name = "$($b.Current.Name)".Trim()
    if (-not $name -or -not $b.Current.IsEnabled -or $b.Current.IsOffscreen) { continue }
    $parent = $walker.GetParent($b)
    if ($parent -and $parent.Current.ControlType -eq $CT::TitleBar) { continue }  # minimize, close
    $out += $b
  }
  return $out
}

function Dialog-Buttons($hwnd) {
  return @([DeskWin]::Children($hwnd, 'Button') | Where-Object { [DeskWin]::IsWindowEnabled($_) -and [DeskWin]::Text($_) })
}

function Find-Popups {
  $found = @()
  $windows = @($AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition))
  $listed = @{}
  foreach ($w in $windows) { try { $listed[[int64]$w.Current.NativeWindowHandle] = $true } catch { } }
  foreach ($h in [DeskWin]::VisibleDialogs()) {
    if (-not $listed[[int64]$h]) { try { $windows += $AE::FromHandle($h) } catch { } }
  }
  foreach ($w in $windows) {
    try {
      $cur = $w.Current
      if ($cur.IsOffscreen) { continue }
      $dialog = $cur.ClassName -eq '#32770'
      $pattern = $null
      $hasPattern = $w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)
      if (-not $hasPattern -and -not $dialog) { continue }
      $proc = 'unknown'
      try { $proc = (Get-Process -Id $cur.ProcessId -ErrorAction Stop).ProcessName } catch { }
      if ($PopupSkip -contains $proc) { continue }
      if ($proc -eq 'explorer' -and -not $dialog) { continue }
      if ($hasPattern -and $pattern.Current.CanMinimize -and -not $dialog) { continue }
      $hwnd = [IntPtr]$cur.NativeWindowHandle
      $buttons = @(Popup-Buttons $w | ForEach-Object { $_.Current.Name.Trim() } | Select-Object -Unique)
      $texts = @($w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
        ForEach-Object { "$($_.Current.Name)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
      if (-not $buttons -and $dialog) {
        $buttons = @(Dialog-Buttons $hwnd | ForEach-Object { [DeskWin]::Text($_) } | Select-Object -Unique)
        $texts = @([DeskWin]::Children($hwnd, 'Static') | ForEach-Object { [DeskWin]::Text($_) } | Where-Object { $_ })
      }
      if (-not $buttons) { continue }
      $text = $texts -join "`n"
      if ($text.Length -gt 600) { $text = $text.Substring(0, 600) }
      $found += @{ hwnd = [int64]$cur.NativeWindowHandle; title = "$($cur.Name)"; process = $proc; text = $text; buttons = $buttons }
    } catch { continue }  # it closed while being read
  }
  # A desktop app's own question drawn inside its page: Claude asks there before restarting to
  # update while Claude Code works (live 10/30). Its window stays the app's main one.
  foreach ($w in $windows) {
    try {
      $cur = $w.Current
      if ($cur.IsOffscreen -or $cur.ClassName -ne 'Chrome_WidgetWin_1') { continue }
      $proc = (Get-Process -Id $cur.ProcessId -ErrorAction Stop).ProcessName
      if ($PageDialogApps -notcontains $proc) { continue }
      foreach ($d in $w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))) {
        $name = "$($d.Current.Name)".Trim()
        $buttons = @(Popup-Buttons $d | ForEach-Object { $_.Current.Name.Trim() } | Select-Object -Unique)
        if (-not $name -or $buttons.Count -lt 2) { continue }
        $texts = @($d.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text))) |
          ForEach-Object { "$($_.Current.Name)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $text = $texts -join "`n"
        if ($text.Length -gt 600) { $text = $text.Substring(0, 600) }
        $found += @{ hwnd = [int64]$cur.NativeWindowHandle; title = $name; process = $proc; text = $text; buttons = $buttons; page = $true }
      }
    } catch { continue }
  }
  return $found
}

# The dialog named $c.title inside the app window $c.hwnd, or $null once it has gone.
function Page-Dialog($c) {
  $w = $null
  try { $w = $AE::FromHandle([IntPtr][int64]$c.hwnd) } catch { return $null }
  try {
    $cond = New-Object System.Windows.Automation.AndCondition(
      (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)),
      (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $c.title)))
    return $w.FindFirst($Tree::Descendants, $cond)
  } catch { return $null }
}

# Presses the button named $c.button in the pop-up $c.hwnd, only while that window still has
# the title it was listed with. True when the window has closed within 3 s.
function Press-Popup($c) {
  if ($c.page) {
    $d = Page-Dialog $c
    if (-not $d) { Fail 'popup-gone' 'the dialog is gone' }
    $button = @(Popup-Buttons $d | Where-Object { $_.Current.Name.Trim() -eq $c.button }) | Select-Object -First 1
    if (-not $button) { Fail 'not-found' 'no such button in the dialog' }
    if (-not (Invoke-Element $button)) { Fail 'press-failed' 'the button did not take the press' }
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 250
      if (-not (Page-Dialog $c)) { return $true }
    }
    return $false
  }
  $w = $null
  try { $w = $AE::FromHandle([IntPtr][int64]$c.hwnd) } catch { }
  if (-not $w) { Fail 'popup-gone' 'the window is gone' }
  try { $title = "$($w.Current.Name)" } catch { Fail 'popup-gone' 'the window is gone' }
  if ($title -ne $c.title) { Fail 'popup-gone' 'the window is gone' }
  $button = @(Popup-Buttons $w | Where-Object { $_.Current.Name.Trim() -eq $c.button }) | Select-Object -First 1
  if (-not $button) {
    $child = @(Dialog-Buttons ([IntPtr][int64]$c.hwnd) | Where-Object { [DeskWin]::Text($_) -eq $c.button }) | Select-Object -First 1
    if (-not $child) { Fail 'not-found' 'no such button in the window' }
    [DeskWin]::Press($child)
  }
  try {
    if ($button -and -not (Invoke-Element $button)) {
      Bring-Front $w
      Click-Element $w $button 'the button'
    }
  } catch {
    # A window of an administrator process refuses this user's UI Automation (UIPI).
    $m = "$($_.Exception.Message)"
    if ($m -match '^DESK:') { throw }
    Fail 'press-failed' "pressing failed: $m"
  }
  $hwnd = [IntPtr][int64]$c.hwnd
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not [DeskWin]::IsWindow($hwnd) -or -not [DeskWin]::IsWindowVisible($hwnd)) { return $true }
  }
  return $false
}

function Run-Command($c) {
  $s = $c.strings
  switch ($c.cmd) {
    'ping' { return @{ ok = $true } }
    'inspect' {
      $w = Find-Window $c.app
      if (-not $w) {
        $usage = $null; $update = $null
        $hidden = if ($s.usage_prefix -or $s.update_prefix) { Find-HiddenWindow $c.app } else { $null }
        if ($hidden) {
          $buttons = $hidden.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
          foreach ($b in $buttons) {
            $n = $b.Current.Name
            if (-not $n) { continue }
            if (-not $usage -and $s.usage_prefix -and $n.StartsWith($s.usage_prefix)) { $usage = $n }
            if (-not $update -and (Is-UpdateButton $s $n)) { $update = $n }
          }
        }
        return @{ ok = $true; window = $false; usage = $usage; update = $update }
      }
      $prompt = Get-Prompt $w $s
      $edit = Find-ByName $w $CT::Edit $s.edit
      # The composer's model and usage buttons, in one pass over the buttons (Claude only).
      $model = $null; $usage = $null; $mode = $null; $running = $false; $update = $null
      if ($s.model_prefix -or $s.usage_prefix -or $s.modes -or $s.stop -or $s.update_prefix) {
        $buttons = $w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
        foreach ($b in $buttons) {
          $n = $b.Current.Name
          if (-not $model -and $s.model_prefix -and $n.StartsWith($s.model_prefix)) { $model = $n }
          if (-not $usage -and $s.usage_prefix -and $n.StartsWith($s.usage_prefix)) { $usage = $n }
          if (-not $update -and (Is-UpdateButton $s $n)) { $update = $n }
          if (-not $mode -and $s.modes -and -not $s.permission_button -and (@($s.modes) -contains $n)) { $mode = $n }
          if ($s.stop -and $n -eq $s.stop) { $running = $true }
        }
      }
      return @{ ok = $true; window = $true; docs = @(Get-Docs $w); edit = [bool]$edit; prompt = $prompt
        model = $model; usage = $usage; mode = $mode; running = $running; update = $update }
    }
    'model' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      if ($c.app -eq 'codex') { return @{ ok = $true; how = (Set-CodexModel $w $page $s $c.model) } }
      return @{ ok = $true; how = (Set-Model $w $page $s $c.model) }
    }
    'effort' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      return @{ ok = $true; how = (Set-Effort $w $page $s $c.effort) }
    }
    'mode' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      if ($c.app -eq 'codex') { return @{ ok = $true; how = (Set-CodexMode $w $page $s $c.mode) } }
      return @{ ok = $true; how = (Set-ClaudeMode $w $page $s $c.mode) }
    }
    'press_update' {
      # The app's own update button (Claude "restart to update", Codex "update"), in its window
      # or its hidden one; Codex then asks again in a dialog whose button has the same name.
      $w = Find-Window $c.app
      if (-not $w) { $w = Find-HiddenWindow $c.app }
      if (-not $w) { Fail 'app-not-running' 'window not found' }
      $b = Find-InApp $w $CT::Button $c.name
      if (-not $b) { Fail 'not-found' 'no update button' }
      if (-not (Invoke-Element $b)) { Fail 'not-invokable' 'the update button has no invoke pattern' }
      if (-not $c.confirm) { return @{ ok = $true; how = 'invoke' } }
      for ($i = 0; $i -lt 16; $i++) {
        Start-Sleep -Milliseconds 250
        $cond = New-Object System.Windows.Automation.AndCondition(
          (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)),
          (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $c.confirm)))
        $roots = @($w) + @($AE::RootElement.FindAll($Tree::Children, [System.Windows.Automation.Condition]::TrueCondition) |
          Where-Object { $_.Current.ProcessId -eq $w.Current.ProcessId -and -not (Same-Element $_ $w) })
        foreach ($root in $roots) {
          foreach ($e in $root.FindAll($Tree::Descendants, $cond)) {
            if (-not (Same-Element $e $b) -and (Invoke-Element $e)) { return @{ ok = $true; how = 'confirmed' } }
          }
        }
      }
      Fail 'update-failed' 'the update was not confirmed'
    }
    'fast' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      return @{ ok = $true; how = (Set-CodexFast $w $page $s ([bool]$c.on)) }
    }
    'stop' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      return @{ ok = $true; how = (Stop-Turn $w $page $s) }
    }
    'usage_card' {
      $w = Find-Window $c.app
      if (-not $w) { $w = Find-HiddenWindow $c.app }
      if (-not $w) { Fail 'app-not-running' 'window not found' }
      $card = Read-UsageCard $w $s
      return @{ ok = $true; rows = @($card.rows); how = $card.how }
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
    'invoke_title' {
      # The sidebar entry: "<title>" or "<title> <note>", but not "<title> <suffix of its menu>".
      $w = Need-Window $c.app
      $hits = @()
      foreach ($b in $w.FindAll($Tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))) {
        $n = $b.Current.Name
        if ($n -eq $c.title -or ($n.StartsWith($c.title + ' ') -and -not ($n.Substring($c.title.Length + 1) -match $s.menu_suffix))) { $hits += $b }
      }
      if ($hits.Count -ne 1) { Fail 'duplicate-title' ("sidebar entries with this title: " + $hits.Count) }
      if (-not (Invoke-Element $hits[0])) { Fail 'not-invokable' 'the sidebar entry has no invoke pattern' }
      return @{ ok = $true }
    }
    'send' {
      $w = Need-Window $c.app
      $page = Need-Doc $w $c.doc
      Paste-Send $w $page $s.edit $c.text @($c.images)
      return @{ ok = $true }
    }
    'popups' { return @{ ok = $true; popups = @(Find-Popups) } }
    'press_popup' { return @{ ok = $true; gone = (Press-Popup $c) } }
    'new_send' {
      $w = Need-Window $c.app
      $before = @(Get-Docs $w)
      # Already on an empty new-conversation page (Codex shows its own box there): use it.
      $fresh = $s.new_edit -and (Find-ByName $w $CT::Edit $s.new_edit)
      if (-not $fresh) {
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
      }
      Start-Sleep -Milliseconds 1500
      # Codex names its new-conversation box differently from a conversation's (read live 10/27).
      $editName = $s.edit
      if ($s.new_edit -and (Find-ByName $w $CT::Edit $s.new_edit)) { $editName = $s.new_edit }
      Paste-Send $w $w $editName $c.text
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
