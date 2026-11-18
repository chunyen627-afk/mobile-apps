# Reads the grey suggested message in a desktop app's empty message box with Windows OCR and
# prints {"ok":true,"text":"..."} as one line of UTF-8 JSON. The suggestion is drawn as the
# box's placeholder and is not in the UI Automation tree (Claude 11/18), so the box is captured
# from the window (PrintWindow: a covered window still draws) and read. Its own process because
# it must be DPI aware to see real pixels, which would change the coordinates uia_worker.ps1
# clicks with. Nothing is written to disk.
# -ImagePath reads a saved picture of the box instead (for trying changes on real pictures).
param([long]$Hwnd, [string]$EditName, [string]$Language = 'zh-Hant-TW', [int]$Shots = 2, [string]$ImagePath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes, System.Runtime.WindowsRuntime
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Runtime.InteropServices;
public static class DeskOcrWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
public static class DeskOcrLighten {
  // Each pixel of `into` becomes the lighter of it and `other` (same size, 32bpp ARGB).
  public static void Into(System.Drawing.Bitmap into, System.Drawing.Bitmap other) {
    var r = new System.Drawing.Rectangle(0, 0, into.Width, into.Height);
    var a = into.LockBits(r, System.Drawing.Imaging.ImageLockMode.ReadWrite, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    var b = other.LockBits(r, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    int n = a.Stride * a.Height;
    var x = new byte[n]; var y = new byte[n];
    Marshal.Copy(a.Scan0, x, 0, n); Marshal.Copy(b.Scan0, y, 0, n);
    for (int i = 0; i < n; i++) if (y[i] > x[i]) x[i] = y[i];
    Marshal.Copy(x, 0, a.Scan0, n);
    into.UnlockBits(a); other.UnlockBits(b);
  }
  // Near-black pixels become white: the placeholder is grey (darkest 102 of 255, live 11/18) and
  // the caret over its first letter black (25), read as part of it ("P4" as "h4").
  public static void DropBlack(System.Drawing.Bitmap bmp, int below) {
    var r = new System.Drawing.Rectangle(0, 0, bmp.Width, bmp.Height);
    var a = bmp.LockBits(r, System.Drawing.Imaging.ImageLockMode.ReadWrite, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
    int n = a.Stride * a.Height;
    var x = new byte[n];
    Marshal.Copy(a.Scan0, x, 0, n);
    for (int i = 0; i + 3 < n; i += 4)
      if (x[i] < below && x[i + 1] < below && x[i + 2] < below) { x[i] = 255; x[i + 1] = 255; x[i + 2] = 255; }
    Marshal.Copy(x, 0, a.Scan0, n);
    bmp.UnlockBits(a);
  }
}
"@
[DeskOcrWin]::SetProcessDPIAware() | Out-Null

function Done($obj) { Write-Output ($obj | ConvertTo-Json -Compress); exit 0 }

if (-not $ImagePath) {
$h = [IntPtr]$Hwnd
if ([DeskOcrWin]::IsIconic($h)) { Done @{ ok = $false; error = 'minimized' } }
$AE = [System.Windows.Automation.AutomationElement]
$window = $AE::FromHandle($h)
$cond = New-Object System.Windows.Automation.AndCondition(
  (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)),
  (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $EditName)))
$edit = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
if (-not $edit) { Done @{ ok = $false; error = 'no-box' } }
$box = $edit.Current.BoundingRectangle
$rect = New-Object DeskOcrWin+RECT
[DeskOcrWin]::GetWindowRect($h, [ref]$rect) | Out-Null
$ww = $rect.Right - $rect.Left; $wh = $rect.Bottom - $rect.Top
$x = [int]($box.X - $rect.Left); $y = [int]($box.Y - $rect.Top)
$bw = [int][Math]::Min($box.Width, $ww - $x); $bh = [int][Math]::Min($box.Height, $wh - $y)
if ($ww -le 0 -or $bw -le 8 -or $bh -le 8 -or $x -lt 0 -or $y -lt 0) { Done @{ ok = $false; error = 'no-box' } }
}

$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
$lang = New-Object Windows.Globalization.Language $Language
if (-not [Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($lang)) { Done @{ ok = $false; error = 'no-ocr-language' } }
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)

# Grey on white made dark, three times larger: the placeholder is light and small (read live 11/18:
# at its own size the OCR split one character in two).
$matrix = New-Object System.Drawing.Imaging.ColorMatrix
$matrix.Matrix00 = 0.6; $matrix.Matrix01 = 0.6; $matrix.Matrix02 = 0.6
$matrix.Matrix10 = 1.2; $matrix.Matrix11 = 1.2; $matrix.Matrix12 = 1.2
$matrix.Matrix20 = 0.2; $matrix.Matrix21 = 0.2; $matrix.Matrix22 = 0.2
$matrix.Matrix40 = -1.0; $matrix.Matrix41 = -1.0; $matrix.Matrix42 = -1.0
$attrs = New-Object System.Drawing.Imaging.ImageAttributes
$attrs.SetColorMatrix($matrix)

# Two shots, each pixel the lighter of them: anything that blinks or moves goes.
$box = $null
if ($ImagePath) {
  $file = [System.Drawing.Bitmap]::FromFile($ImagePath)
  $bw = $file.Width; $bh = $file.Height
  $box = $file.Clone((New-Object System.Drawing.Rectangle 0, 0, $bw, $bh), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $file.Dispose(); $Shots = 0
}
for ($i = 0; $i -lt $Shots; $i++) {
  if ($i -gt 0) { Start-Sleep -Milliseconds 300 }
  $full = New-Object System.Drawing.Bitmap $ww, $wh
  $g = [System.Drawing.Graphics]::FromImage($full)
  $dc = $g.GetHdc(); [DeskOcrWin]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc); $g.Dispose()
  $shot = $full.Clone((New-Object System.Drawing.Rectangle $x, $y, $bw, $bh), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $full.Dispose()
  if ($box) { [DeskOcrLighten]::Into($box, $shot); $shot.Dispose() } else { $box = $shot }
}
[DeskOcrLighten]::DropBlack($box, 70)
# A white margin all round: text touching the edge was dropped too.
$pad = 48
$big = New-Object System.Drawing.Bitmap ($bw * 3 + 2 * $pad), ($bh * 3 + 2 * $pad)
$g = [System.Drawing.Graphics]::FromImage($big)
$g.Clear([System.Drawing.Color]::White)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($box, (New-Object System.Drawing.Rectangle $pad, $pad, ($bw * 3), ($bh * 3)), 0, 0, $bw, $bh, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
$g.Dispose(); $box.Dispose()
$memory = New-Object System.IO.MemoryStream
$big.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png); $big.Dispose()
$memory.Position = 0
$stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
Done @{ ok = $true; text = (($result.Lines | ForEach-Object { $_.Text }) -join ' ') }
