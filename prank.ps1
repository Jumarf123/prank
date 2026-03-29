[CmdletBinding()]
param(
    [int]$Count = 10,
    [string]$CacheRoot = (Join-Path $env:TEMP "prank-cache"),
    [int]$MoveSteps = 10,
    [int]$MoveDelayMs = 25,
    [int]$CyclesPerWallpaper = 3,
    [int]$PauseMs = 200,
    [int]$Iterations = 0,
    [switch]$DownloadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoOwner = "Jumarf123"
$script:RepoName = "prank"
$script:RepoBranch = "main"
$script:RawRoot = "https://raw.githubusercontent.com/$($script:RepoOwner)/$($script:RepoName)/$($script:RepoBranch)"
$script:ManifestUrl = "$($script:RawRoot)/images/manifest.txt"
$script:ImageCachePath = Join-Path $CacheRoot "images"
$script:SupportedImagePattern = '\.(png|jpe?g|bmp)$'

function Set-Tls12 {
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
    }
}

function Get-RepoImageManifest {
    Set-Tls12
    $content = Invoke-RestMethod -Uri $script:ManifestUrl
    @(
        $content -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") -and $_ -match $script:SupportedImagePattern }
    )
}

function Sync-RepoImages {
    param(
        [string]$DestinationPath
    )

    $names = Get-RepoImageManifest
    if ($names.Count -eq 0) {
        throw "В manifest.txt нет доступных картинок."
    }

    $null = New-Item -Path $DestinationPath -ItemType Directory -Force

    foreach ($name in $names) {
        $targetPath = Join-Path $DestinationPath $name
        if (Test-Path $targetPath) {
            continue
        }

        $imageUrl = "$($script:RawRoot)/images/$name"
        Invoke-WebRequest -Uri $imageUrl -OutFile $targetPath
    }

    @(
        Get-ChildItem -Path $DestinationPath -File |
        Where-Object { $_.Extension -match $script:SupportedImagePattern }
    )
}

function Get-RandomImages {
    param(
        [string]$Path,
        [int]$ImageCount
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    $files = @(
        Get-ChildItem -Path $Path -File |
        Where-Object { $_.Extension -match $script:SupportedImagePattern }
    )

    if ($files.Count -eq 0) {
        return @()
    }

    @($files | Get-Random -Count ([Math]::Min($ImageCount, $files.Count)))
}

function Invoke-DoEvents {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{
            param($state)
            ([System.Windows.Threading.DispatcherFrame]$state).Continue = $false
            return $null
        },
        $frame
    ) | Out-Null

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Move-WindowsRandomly {
    param(
        [int]$Steps,
        [int]$StepDelayMs
    )

    $screens = [System.Windows.Forms.Screen]::AllScreens
    $targets = @(
        foreach ($entry in $script:windows) {
            $win = $entry.Window
            $scr = $screens[$script:rnd.Next(0, $screens.Length)]
            $targetLeft = $scr.Bounds.Left + $script:rnd.Next(0, [Math]::Max(1, $scr.Bounds.Width - [int]$win.Width))
            $targetTop = $scr.Bounds.Top + $script:rnd.Next(0, [Math]::Max(1, $scr.Bounds.Height - [int]$win.Height))

            [PSCustomObject]@{
                Window = $win
                DX = ($targetLeft - $win.Left) / $Steps
                DY = ($targetTop - $win.Top) / $Steps
            }
        }
    )

    for ($i = 0; $i -lt $Steps; $i++) {
        foreach ($target in $targets) {
            $target.Window.Left += $target.DX
            $target.Window.Top += $target.DY
        }

        Invoke-DoEvents
        Start-Sleep -Milliseconds $StepDelayMs
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$wallpaperCode = @"
using System;
using System.Runtime.InteropServices;
public static class Wallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(
        int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

if (-not ([System.Management.Automation.PSTypeName]"Wallpaper").Type) {
    Add-Type $wallpaperCode
}

$SPI_SETDESKWALLPAPER = 0x0014
$SPIF_UPDATEINIFILE = 0x01
$SPIF_SENDWININICHANGE = 0x02

$null = Sync-RepoImages -DestinationPath $script:ImageCachePath

if ($DownloadOnly) {
    Write-Host "Картинки скачаны в $script:ImageCachePath"
    return
}

$images = Get-RandomImages -Path $script:ImageCachePath -ImageCount $Count
if ($images.Count -eq 0) {
    throw "Картинки из GitHub-репозитория не найдены."
}

$script:rnd = [System.Random]::new()
$screens = [System.Windows.Forms.Screen]::AllScreens
$script:windows = [System.Collections.ArrayList]::new()

foreach ($imgFile in $images) {
    [xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    Width="400"
    Height="300"
    Opacity="0.96">
    <Grid>
        <Border CornerRadius="18" BorderThickness="3" BorderBrush="#AAFFFFFF">
            <Image x:Name="img" Stretch="UniformToFill"/>
        </Border>
    </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $win = [System.Windows.Markup.XamlReader]::Load($reader)

    $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.UriSource = [Uri]::new($imgFile.FullName)
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()

    $win.FindName("img").Source = $bitmap

    $width = $script:rnd.Next(220, 641)
    $height = $script:rnd.Next(180, 521)
    $screen = $screens[$script:rnd.Next(0, $screens.Length)]

    $win.Width = $width
    $win.Height = $height
    $win.Left = $screen.Bounds.Left + $script:rnd.Next(0, [Math]::Max(1, $screen.Bounds.Width - $width))
    $win.Top = $screen.Bounds.Top + $script:rnd.Next(0, [Math]::Max(1, $screen.Bounds.Height - $height))

    [void]$script:windows.Add([PSCustomObject]@{
        Window = $win
        File = $imgFile.FullName
    })
}

foreach ($entry in $script:windows) {
    $entry.Window.Show()
}

Invoke-DoEvents

$index = 0
try {
    while ($true) {
        $entry = $script:windows[$index % $script:windows.Count]
        [Wallpaper]::SystemParametersInfo(
            $SPI_SETDESKWALLPAPER,
            0,
            $entry.File,
            $SPIF_UPDATEINIFILE -bor $SPIF_SENDWININICHANGE
        ) | Out-Null

        for ($moveIndex = 0; $moveIndex -lt $CyclesPerWallpaper; $moveIndex++) {
            Move-WindowsRandomly -Steps $MoveSteps -StepDelayMs $MoveDelayMs
            Start-Sleep -Milliseconds $PauseMs
            Invoke-DoEvents
        }

        $index++
        if ($Iterations -gt 0 -and $index -ge $Iterations) {
            break
        }
    }
}
finally {
    foreach ($entry in $script:windows) {
        try {
            $entry.Window.Close()
        }
        catch {
        }
    }
}
