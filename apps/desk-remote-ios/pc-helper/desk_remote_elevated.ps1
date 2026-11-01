# Desk remote elevated companion: runs an administrator command only after the phone approved it.
#
# Started at logon by the scheduled task "DeskRemoteElevated" with highest privileges, from an
# administrators-only copy in %ProgramData%\DeskRemote\bin (never from a user-writable folder,
# and with powershell.exe rather than a user-installed interpreter).
#
# Protocol: one JSON line in, one JSON line out, per TCP connection on 127.0.0.1 only. Every
# request carries the local submit token (a file only this user can read). That token lets a
# caller ask, list and report; it can never approve. Approval is an HMAC-SHA256, made on the
# phone with a key that only the phone and this companion's admin-only config hold, over
#   "<id>\n<sha256 of the exact content>\n<cwd>\n<expires>"
# so a relay that showed the phone other content, or a replayed or late approval, is refused.
# Approved content runs from an admin-only copy: what the phone saw is exactly what runs.
#
# ASCII only (PowerShell 5.1 reads BOM-less scripts in the ANSI code page).
param([string]$Config = (Join-Path $env:ProgramData 'DeskRemote\elevated.json'))
$ErrorActionPreference = 'Stop'

$cfg = [IO.File]::ReadAllText($Config) | ConvertFrom-Json
$root = Split-Path -Parent $Config
$work = Join-Path $root 'pending'
$logFile = Join-Path $root 'elevated.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$keyHex = "$($cfg.elevate_key)"
$key = New-Object byte[] ($keyHex.Length / 2)
for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = [Convert]::ToByte($keyHex.Substring($i * 2, 2), 16) }
$token = "$($cfg.submit_token)"
$ttl = 600
$maxPending = 3
$perMinute = 5
$maxContent = 100000
$maxOutput = 1000000
# The child never loads modules from user-writable folders.
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules"

$requests = @{}
$recent = New-Object System.Collections.ArrayList
$asked = New-Object System.Collections.ArrayList
$utf8 = New-Object Text.UTF8Encoding $false

function Log($text) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $text
  [IO.File]::AppendAllText($logFile, $line + "`r`n", $utf8)
}

function Now() { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Same-Text($a, $b) {
  $x = $utf8.GetBytes("$a"); $y = $utf8.GetBytes("$b")
  if ($x.Length -ne $y.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $x.Length; $i++) { $diff = $diff -bor ($x[$i] -bxor $y[$i]) }
  return $diff -eq 0
}

function Hex($bytes) { return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '') }

function Sha256Hex($text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return Hex ($sha.ComputeHash($utf8.GetBytes("$text"))) } finally { $sha.Dispose() }
}

function Expected-Mac($r) {
  $message = "$($r.id)`n$(Sha256Hex $r.content)`n$($r.cwd)`n$($r.expires)"
  $mac = New-Object Security.Cryptography.HMACSHA256 (, $key)
  try { return Hex ($mac.ComputeHash($utf8.GetBytes($message))) } finally { $mac.Dispose() }
}

function Public($r) {
  return [ordered]@{ id = $r.id; kind = $r.kind; name = $r.name; content = $r.content; cwd = $r.cwd;
                     created = $r.created; expires = $r.expires }
}

function Finish($r, $state, $exitCode, $stdout, $stderr) {
  $r.state = $state; $r.exitCode = $exitCode; $r.stdout = $stdout; $r.stderr = $stderr; $r.finished = Now
  [void]$recent.Insert(0, $r)
  while ($recent.Count -gt 10) { $recent.RemoveAt($recent.Count - 1) }
  $head = $r.content.Substring(0, [Math]::Min(200, $r.content.Length)) -replace '[\r\n]+', ' '
  Log "$state $($r.id) exit=$exitCode content=$head"
}

function Read-Capped($path) {
  if (-not (Test-Path $path)) { return '' }
  $text = [IO.File]::ReadAllText($path, $utf8)
  if ($text.Length -gt $maxOutput) { $text = $text.Substring(0, $maxOutput) + "`n(output cut at $maxOutput characters)" }
  return $text
}

function Start-Approved($r) {
  $script = Join-Path $work "$($r.id).ps1"
  $out = Join-Path $work "$($r.id).out"
  $err = Join-Path $work "$($r.id).err"
  $body = "[Console]::OutputEncoding = [Text.Encoding]::UTF8`r`n" + $r.content
  [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding $true))
  $dir = if ($r.cwd -and (Test-Path -LiteralPath $r.cwd -PathType Container)) { $r.cwd } else { $work }
  $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
  $r.process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList $argList -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
  $null = $r.process.Handle  # without this, ExitCode stays empty for a -PassThru process (found in tests)
  $r.state = 'running'
  $r.deadline = (Now) + $r.timeout
  Log "running $($r.id)"
}

function Update-All {
  $now = Now
  foreach ($r in @($requests.Values)) {
    if ($r.state -eq 'pending' -and $now -gt $r.expires) {
      $requests.Remove($r.id); Finish $r 'expired' 126 '' 'the phone did not approve in time'
    } elseif ($r.state -eq 'running') {
      if ($r.process.HasExited) {
        $requests.Remove($r.id)
        Finish $r 'done' $r.process.ExitCode (Read-Capped (Join-Path $work "$($r.id).out")) (Read-Capped (Join-Path $work "$($r.id).err"))
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $work "$($r.id).*")
      } elseif ($now -gt $r.deadline) {
        try { $r.process.Kill() } catch {}
        $requests.Remove($r.id); Finish $r 'timeout' 124 '' "stopped after $($r.timeout) seconds"
      }
    }
  }
}

function Find-Any($id) {
  if ($requests.ContainsKey("$id")) { return $requests["$id"] }
  foreach ($r in $recent) { if ($r.id -eq $id) { return $r } }
  return $null
}

function Handle($m) {
  if (-not (Same-Text $m.token $token)) { return @{ ok = $false; error = 'unauthorized' } }
  switch ("$($m.op)") {
    'request' {
      $content = "$($m.content)"
      if (-not $content.Trim()) { return @{ ok = $false; error = 'empty' } }
      if ($content.Length -gt $maxContent) { return @{ ok = $false; error = 'too-large' } }
      $now = Now
      $live = @($asked | Where-Object { $now - $_ -lt 60 })
      $asked.Clear(); foreach ($t in $live) { [void]$asked.Add($t) }
      $waiting = @($requests.Values | Where-Object { $_.state -eq 'pending' }).Count
      if ($waiting -ge $maxPending -or $asked.Count -ge $perMinute) { return @{ ok = $false; error = 'busy' } }
      [void]$asked.Add($now)
      $bytes = New-Object byte[] 8
      [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
      $timeout = [int]$m.timeout
      if ($timeout -le 0) { $timeout = 600 }
      $timeout = [Math]::Min($timeout, 3600)
      $kind = if ("$($m.kind)" -eq 'script') { 'script' } else { 'command' }
      $r = @{ id = (Hex $bytes); kind = $kind; name = "$($m.name)"; content = $content; cwd = "$($m.cwd)";
              created = $now; expires = $now + $ttl; timeout = $timeout; state = 'pending' }
      $requests[$r.id] = $r
      Log "asked $($r.id) $kind"
      return @{ ok = $true; id = $r.id; expires = $r.expires }
    }
    'list' {
      $pending = @($requests.Values | Where-Object { $_.state -eq 'pending' } | Sort-Object { $_.created } | ForEach-Object { Public $_ })
      $done = @($recent | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; name = $_.name; state = $_.state;
        exitCode = $_.exitCode; finished = $_.finished;
        content = $_.content.Substring(0, [Math]::Min(500, $_.content.Length));
        output = ("$($_.stdout)" + "$($_.stderr)").Substring(0, [Math]::Min(2000, ("$($_.stdout)" + "$($_.stderr)").Length)) } })
      return @{ ok = $true; pending = $pending; recent = $done }
    }
    'status' {
      $r = Find-Any $m.id
      if (-not $r) { return @{ ok = $false; error = 'not-found' } }
      return @{ ok = $true; state = $r.state; exitCode = $r.exitCode; stdout = $r.stdout; stderr = $r.stderr; expires = $r.expires }
    }
    'decide' {
      $r = $requests["$($m.id)"]
      if (-not $r -or $r.state -ne 'pending') { return @{ ok = $false; error = 'not-found' } }
      if ((Now) -gt $r.expires) { return @{ ok = $false; error = 'expired' } }
      if ("$($m.decision)" -eq 'deny') {
        $requests.Remove($r.id); Finish $r 'denied' 126 '' 'denied on the phone'
        return @{ ok = $true; state = 'denied' }
      }
      if ("$($m.decision)" -ne 'allow') { return @{ ok = $false; error = 'bad-request' } }
      if (-not (Same-Text ("$($m.hmac)".ToLower()) (Expected-Mac $r))) {
        Log "bad signature for $($r.id)"
        return @{ ok = $false; error = 'bad-signature' }
      }
      Start-Approved $r
      return @{ ok = $true; state = 'running' }
    }
    default { return @{ ok = $false; error = 'bad-request' } }
  }
}

function Escape-Json($json) {
  return [regex]::Replace($json, '[^\x00-\x7F]', { param($x) '\u{0:x4}' -f [int][char]$x.Value })
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, [int]$cfg.port)
$listener.Start()
Log "listening on 127.0.0.1:$($cfg.port)"
while ($true) {
  try { Update-All } catch { Log "update failed: $($_.Exception.Message)" }
  if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
  $client = $listener.AcceptTcpClient()
  try {
    $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
    $stream = $client.GetStream()
    $reader = New-Object IO.StreamReader($stream, $utf8)
    $writer = New-Object IO.StreamWriter($stream, $utf8)
    $line = $reader.ReadLine()
    if ($line -and $line.Length -lt 300000) {
      try { $answer = Handle ($line | ConvertFrom-Json) } catch { $answer = @{ ok = $false; error = 'bad-request' } }
    } else { $answer = @{ ok = $false; error = 'bad-request' } }
    $writer.WriteLine((Escape-Json ($answer | ConvertTo-Json -Compress -Depth 5)))
    $writer.Flush()
  } catch {
    Log "connection failed: $($_.Exception.Message)"
  } finally {
    $client.Close()
  }
}
