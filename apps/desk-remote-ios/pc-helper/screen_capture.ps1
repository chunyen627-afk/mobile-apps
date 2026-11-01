# Prints a JPEG of the whole desktop (all monitors), at most -MaxWidth wide, as one line of base64
# on stdout. The picture never touches the disk (the user asked 10/27 that screenshots are not
# kept on the PC). Its own process because it must be DPI aware to see real pixels, which would
# change the coordinates uia_worker.ps1 clicks with. Exit code 3 when the screen cannot be read
# (locked).
param([int]$MaxWidth = 1600, [int]$Quality = 70)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class DeskDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[DeskDpi]::SetProcessDPIAware() | Out-Null
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$full = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($full)
try { $g.CopyFromScreen($b.X, $b.Y, 0, 0, $full.Size) } catch { exit 3 } finally { $g.Dispose() }
$scale = [Math]::Min(1.0, $MaxWidth / $b.Width)
$w = [int]($b.Width * $scale); $h = [int]($b.Height * $scale)
$small = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($small)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($full, 0, 0, $w, $h)
$g.Dispose(); $full.Dispose()
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$params = New-Object System.Drawing.Imaging.EncoderParameters 1
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
$memory = New-Object System.IO.MemoryStream
$small.Save($memory, $codec, $params)
$small.Dispose()
[Console]::Out.Write([Convert]::ToBase64String($memory.ToArray()))
$memory.Dispose()
