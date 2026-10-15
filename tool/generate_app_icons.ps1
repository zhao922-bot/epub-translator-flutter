#Requires -Version 5.1
<#
Regenerate platform resources from the approved FolioFerry master artwork.
Only resize and encode the artwork; keep the master unchanged.
Run with Windows PowerShell or PowerShell on Windows (System.Drawing).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path -Parent $PSScriptRoot
$master = Join-Path $repo 'assets\branding\folioferry-master.png'
$source = [Drawing.Image]::FromFile($master)

function Get-IconPng {
    param([int]$Size)
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $attributes = [Drawing.Imaging.ImageAttributes]::new()
    $stream = [IO.MemoryStream]::new()
    try {
        $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $rect = [Drawing.Rectangle]::new(0, 0, $Size, $Size)
        $graphics.DrawImage($source, $rect, 0, 0, $source.Width, $source.Height, [Drawing.GraphicsUnit]::Pixel, $attributes)
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        $stream.Dispose()
        $attributes.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Write-IconPng {
    param([string]$RelativePath, [int]$Size)
    $target = Join-Path $repo $RelativePath
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    [IO.File]::WriteAllBytes($target, (Get-IconPng $Size))
    Write-Host "$RelativePath ($Size x $Size)"
}

try {
    if ($source.Width -ne $source.Height) { throw 'The master icon must be square.' }
    Write-IconPng 'assets\icons\app_icon.png' 512
    $densities = @{ 'mdpi'=48; 'hdpi'=72; 'xhdpi'=96; 'xxhdpi'=144; 'xxxhdpi'=192 }
    foreach ($density in $densities.Keys) {
        Write-IconPng "android\app\src\main\res\mipmap-$density\ic_launcher.png" $densities[$density]
    }
    Write-IconPng 'android\app\src\main\res\drawable-nodpi\ic_brand_foreground.png' 432
    foreach ($size in @(16, 32, 64, 128, 256, 512, 1024)) {
        Write-IconPng "macos\Runner\Assets.xcassets\AppIcon.appiconset\app_icon_$size.png" $size
    }

    # Modern Windows ICO: one PNG-encoded image per supported display size.
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $images = @($sizes | ForEach-Object { ,(Get-IconPng $_) })
    $target = Join-Path $repo 'windows\runner\resources\app_icon.ico'
    $stream = [IO.File]::Create($target)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dimension = $sizes[$i]
            if ($dimension -eq 256) { $dimension = 0 }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$i].Length)
            $writer.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($image in $images) { $writer.Write([byte[]]$image) }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
    Write-Host 'windows\runner\resources\app_icon.ico (16-256 px)'
} finally {
    $source.Dispose()
}
