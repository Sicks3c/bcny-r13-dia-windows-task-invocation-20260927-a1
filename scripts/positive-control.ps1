param(
    [Parameter(Mandatory = $true)]
    [string]$MarkerPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'R13 UIA Positive Control'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(430, 180)
$form.TopMost = $true

$button = New-Object System.Windows.Forms.Button
$button.Name = 'R13PositiveControlButton'
$button.Text = 'R13 Positive Control'
$button.Location = New-Object System.Drawing.Point(95, 50)
$button.Size = New-Object System.Drawing.Size(220, 42)
$button.Add_Click({
    'invoked' | Set-Content -Encoding ascii -Path $MarkerPath
    $form.Close()
})
$form.Controls.Add($button)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 180000
$timer.Add_Tick({ $form.Close() })
$timer.Start()
[void]$form.ShowDialog()

