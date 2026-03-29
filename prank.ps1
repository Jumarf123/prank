[CmdletBinding()]
param(
    [ValidateRange(1, 256)]
    [int]$Count = 10,
    [string]$CacheRoot = (Join-Path $env:TEMP "img-cache"),
    [ValidateRange(1, 100)]
    [int]$FrameDelayMs = 10,
    [ValidateRange(1, 200)]
    [int]$WallpaperIntervalMs = 1800,
    [ValidateRange(100, 8000)]
    [int]$MinSpeed = 520,
    [ValidateRange(100, 8000)]
    [int]$MaxSpeed = 860,
    [int]$Iterations = 0,
    [switch]$DownloadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-BytesToText {
    param(
        [int[]]$Bytes
    )

    [Text.Encoding]::UTF8.GetString([byte[]]$Bytes)
}

function Set-Tls12 {
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::DefaultConnectionLimit = 16
    }
    catch {
    }
}

function Get-Client {
    if ($null -eq $script:Client) {
        Set-Tls12
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $script:Client = [Net.Http.HttpClient]::new($handler)
        $script:Client.Timeout = [TimeSpan]::FromSeconds(30)
    }

    $script:Client
}

function Join-SourcePath {
    param(
        [string]$Part
    )

    "{0}/{1}" -f $script:OriginRoot.TrimEnd("/"), $Part.TrimStart("/")
}

function Get-ManifestNames {
    $content = (Get-Client).GetStringAsync((Join-SourcePath -Part $script:ManifestPart)).GetAwaiter().GetResult()
    @(
        $content -split "\r?\n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") -and $_ -match $script:ImagePattern }
    )
}

function Select-ImageNames {
    param(
        [int]$ImageCount
    )

    $names = Get-ManifestNames
    if ($names.Count -eq 0) {
        throw "Нет доступных картинок."
    }

    @($names | Get-Random -Count ([Math]::Min($ImageCount, $names.Count)))
}

function Sync-Images {
    param(
        [string]$DestinationPath,
        [string[]]$Names
    )

    $null = New-Item -Path $DestinationPath -ItemType Directory -Force
    $pending = [System.Collections.Generic.List[object]]::new()
    $client = Get-Client

    foreach ($name in $Names) {
        $targetPath = Join-Path $DestinationPath $name
        if ((Test-Path $targetPath -PathType Leaf) -and (Get-Item $targetPath).Length -gt 0) {
            continue
        }

        $tempPath = "{0}.{1}.part" -f $targetPath, [guid]::NewGuid().ToString("N")
        $uri = Join-SourcePath -Part ("{0}/{1}" -f $script:FolderPart, $name)
        $task = $client.GetByteArrayAsync($uri)

        $pending.Add([PSCustomObject]@{
            Name = $name
            TargetPath = $targetPath
            TempPath = $tempPath
            Task = $task
        }) | Out-Null
    }

    if ($pending.Count -gt 0) {
        try {
            [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]($pending | ForEach-Object Task))
        }
        catch {
        }

        foreach ($item in $pending) {
            if ($item.Task.IsFaulted) {
                throw $item.Task.Exception.GetBaseException()
            }

            [IO.File]::WriteAllBytes($item.TempPath, $item.Task.GetAwaiter().GetResult())
            if (Test-Path $item.TargetPath -PathType Leaf) {
                Remove-Item -Path $item.TargetPath -Force -ErrorAction SilentlyContinue
            }

            Move-Item -Path $item.TempPath -Destination $item.TargetPath -Force
        }
    }

    @(
        foreach ($name in $Names) {
            $path = Join-Path $DestinationPath $name
            if (Test-Path $path -PathType Leaf) {
                Get-Item $path
            }
        }
    )
}

function Invoke-DoEvents {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        [Windows.Threading.DispatcherOperationCallback]{
            param($state)
            ([Windows.Threading.DispatcherFrame]$state).Continue = $false
            $null
        },
        $frame
    ) | Out-Null

    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Set-WallpaperPath {
    param(
        [string]$Path
    )

    [DesktopApi]::SystemParametersInfo(
        $script:WallpaperAction,
        0,
        $Path,
        $script:WallpaperFlags
    ) | Out-Null
}

function Get-RestorePath {
    try {
        (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallPaper).WallPaper
    }
    catch {
        ""
    }
}

function Start-RestoreWatcher {
    param(
        [int]$ParentId,
        [string]$StatePath
    )

    $safeStatePath = $StatePath.Replace("'", "''")
    $helper = @"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ExitApi {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
while (Get-Process -Id $ParentId -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 300
}
if (Test-Path '$safeStatePath') {
    `$value = Get-Content -Path '$safeStatePath' -Raw -ErrorAction SilentlyContinue
    [ExitApi]::SystemParametersInfo(20, 0, `$value, 3) | Out-Null
    Remove-Item -Path '$safeStatePath' -Force -ErrorAction SilentlyContinue
}
"@

    Start-Process -WindowStyle Hidden -FilePath "powershell" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-Command", $helper
    ) | Out-Null
}

function Start-WallpaperLoop {
    param(
        [int]$ParentId,
        [string[]]$Paths,
        [int]$IntervalMs
    )

    if ($Paths.Count -eq 0) {
        return
    }

    $pathLiteral = ($Paths | ForEach-Object {
        "'{0}'" -f ($_.Replace("'", "''"))
    }) -join ",`r`n"

    $helper = @"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CycleApi {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
`$paths = @(
$pathLiteral
)
`$index = 0
while (Get-Process -Id $ParentId -ErrorAction SilentlyContinue) {
    [CycleApi]::SystemParametersInfo(20, 0, `$paths[`$index % `$paths.Count], 3) | Out-Null
    `$index++
    Start-Sleep -Milliseconds $IntervalMs
}
"@

    Start-Process -WindowStyle Hidden -FilePath "powershell" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-Command", $helper
    ) | Out-Null
}

function Set-MotionVector {
    param(
        [pscustomobject]$Entry,
        [double]$Angle,
        [double]$Speed
    )

    $clampedSpeed = [Math]::Max($MinSpeed, [Math]::Min($MaxSpeed, $Speed))
    $Entry.VX = [Math]::Cos($Angle) * $clampedSpeed
    $Entry.VY = [Math]::Sin($Angle) * $clampedSpeed
}

function Initialize-Motion {
    param(
        [pscustomobject]$Entry
    )

    Set-MotionVector -Entry $Entry -Angle ($script:Random.NextDouble() * [Math]::PI * 2) -Speed ($MinSpeed + ($script:Random.NextDouble() * ($MaxSpeed - $MinSpeed)))
}

function Update-Windows {
    param(
        [double]$DeltaSeconds
    )

    foreach ($entry in $script:Windows) {
        $window = $entry.Window
        $newLeft = $window.Left + ($entry.VX * $DeltaSeconds)
        $newTop = $window.Top + ($entry.VY * $DeltaSeconds)
        $maxLeft = $script:DesktopBounds.Right - $window.Width
        $maxTop = $script:DesktopBounds.Bottom - $window.Height

        if ($newLeft -lt $script:DesktopBounds.Left) {
            $newLeft = $script:DesktopBounds.Left
            $entry.VX = [Math]::Abs($entry.VX)
        }
        elseif ($newLeft -gt $maxLeft) {
            $newLeft = $maxLeft
            $entry.VX = -[Math]::Abs($entry.VX)
        }

        if ($newTop -lt $script:DesktopBounds.Top) {
            $newTop = $script:DesktopBounds.Top
            $entry.VY = [Math]::Abs($entry.VY)
        }
        elseif ($newTop -gt $maxTop) {
            $newTop = $maxTop
            $entry.VY = -[Math]::Abs($entry.VY)
        }

        $window.Left = $newLeft
        $window.Top = $newTop
    }
}

function Restore-State {
    if ($script:CleanupDone) {
        return
    }

    $script:CleanupDone = $true
    $script:Running = $false

    foreach ($entry in $script:Windows) {
        try {
            $entry.Window.Close()
        }
        catch {
        }
    }

    if ($null -ne $script:OriginalWallpaper) {
        try {
            Set-WallpaperPath -Path $script:OriginalWallpaper
        }
        catch {
        }
    }

    if ($script:StatePath -and (Test-Path $script:StatePath)) {
        Remove-Item -Path $script:StatePath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $script:ExitSubscription) {
        Unregister-Event -SubscriptionId $script:ExitSubscription.Id -ErrorAction SilentlyContinue
    }

    if ($null -ne $script:Client) {
        $script:Client.Dispose()
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Net.Http

$native = @"
using System;
using System.Runtime.InteropServices;
public static class DesktopApi {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

if (-not ([Management.Automation.PSTypeName]"DesktopApi").Type) {
    Add-Type $native
}

$script:OriginRoot = Convert-BytesToText @(104,116,116,112,115,58,47,47,114,97,119,46,103,105,116,104,117,98,117,115,101,114,99,111,110,116,101,110,116,46,99,111,109,47,74,117,109,97,114,102,49,50,51,47,112,114,97,110,107,47,109,97,105,110)
$script:FolderPart = Convert-BytesToText @(105,109,97,103,101,115)
$script:ManifestPart = Convert-BytesToText @(105,109,97,103,101,115,47,109,97,110,105,102,101,115,116,46,116,120,116)
$script:ImagePattern = "\.(png|jpe?g|bmp)$"
$script:ImagePath = Join-Path $CacheRoot $script:FolderPart
$script:WallpaperAction = 0x0014
$script:WallpaperFlags = 0x01 -bor 0x02
$script:Random = [Random]::new()
$script:Screens = [Windows.Forms.Screen]::AllScreens
$script:DesktopBounds = [Windows.Forms.SystemInformation]::VirtualScreen
$script:Windows = [Collections.ArrayList]::new()
$script:CleanupDone = $false
$script:Running = $true
$script:Client = $null
$script:ExitSubscription = $null
$script:OriginalWallpaper = Get-RestorePath
$script:StatePath = Join-Path $env:TEMP ("{0}.txt" -f [guid]::NewGuid().ToString("N"))

Set-Content -Path $script:StatePath -Value $script:OriginalWallpaper -NoNewline -Encoding UTF8
Start-RestoreWatcher -ParentId $PID -StatePath $script:StatePath
$script:ExitSubscription = Register-EngineEvent -SourceIdentifier "PowerShell.Exiting" -SupportEvent -Action {
    try {
        Restore-State
    }
    catch {
    }
}

$selected = @(Select-ImageNames -ImageCount $Count)
$images = @(Sync-Images -DestinationPath $script:ImagePath -Names $selected)

if ($DownloadOnly) {
    Write-Host "Картинки скачаны в $script:ImagePath"
    Restore-State
    return
}

if ($images.Count -eq 0) {
    Restore-State
    throw "Картинки не найдены."
}

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

    $reader = [Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.UriSource = [Uri]::new($imgFile.FullName)
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()

    $window.FindName("img").Source = $bitmap

    $width = $script:Random.Next(220, 641)
    $height = $script:Random.Next(180, 521)
    $screen = $script:Screens[$script:Random.Next(0, $script:Screens.Length)]

    $window.Width = $width
    $window.Height = $height
    $window.Left = $screen.Bounds.Left + $script:Random.Next(0, [Math]::Max(1, $screen.Bounds.Width - $width))
    $window.Top = $screen.Bounds.Top + $script:Random.Next(0, [Math]::Max(1, $screen.Bounds.Height - $height))

    $entry = [PSCustomObject]@{
        Window = $window
        File = $imgFile.FullName
        VX = 0.0
        VY = 0.0
    }

    Initialize-Motion -Entry $entry
    [void]$script:Windows.Add($entry)
}

foreach ($entry in $script:Windows) {
    $entry.Window.Show()
}

Invoke-DoEvents
Start-WallpaperLoop -ParentId $PID -Paths ($images.FullName) -IntervalMs $WallpaperIntervalMs

$index = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastFrameTick = 0
$nextWallpaperTick = 0

try {
    while ($script:Running) {
        $now = $clock.ElapsedMilliseconds
        $deltaSeconds = [Math]::Max(0.001, ($now - $lastFrameTick) / 1000.0)
        $lastFrameTick = $now

        if ($Iterations -gt 0 -and $now -ge $nextWallpaperTick) {
            $index++
            $nextWallpaperTick = $now + $WallpaperIntervalMs

            if ($index -ge $Iterations) {
                break
            }
        }

        Update-Windows -DeltaSeconds $deltaSeconds
        Invoke-DoEvents
        Start-Sleep -Milliseconds $FrameDelayMs
    }
}
finally {
    Restore-State
}
