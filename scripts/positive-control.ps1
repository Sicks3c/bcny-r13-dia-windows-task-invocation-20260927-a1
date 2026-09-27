param(
    [Parameter(Mandatory = $true)]
    [string]$MarkerPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$window = New-Object System.Windows.Window
$window.Title = 'R13 UIA Positive Control'
$window.WindowStartupLocation = 'CenterScreen'
$window.Width = 430
$window.Height = 180
$window.Topmost = $true

$button = New-Object System.Windows.Controls.Button
$button.Name = 'R13PositiveControlButton'
$button.Content = 'R13 Positive Control'
$button.Width = 220
$button.Height = 42
$button.Add_Click({
    'invoked' | Set-Content -Encoding ascii -Path $MarkerPath
    $window.Close()
})
$window.Content = $button

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes(3)
$timer.Add_Tick({ $window.Close() })
$timer.Start()
[void]$window.ShowDialog()
