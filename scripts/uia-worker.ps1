param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('snapshot', 'invoke', 'invokeText', 'submit', 'onboard', 'code')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$ProcessIds,
    [string]$Name,
    [string]$ControlType,
    [string]$ValueBase64,
    [string]$ValueFile,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class R13UiaWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@

$pidSet = @{}
foreach ($part in $ProcessIds.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
    $pidSet[[int]$part] = $true
}
$handles = New-Object System.Collections.Generic.List[IntPtr]
$callback = [R13UiaWin32+EnumWindowsProc]{
    param([IntPtr]$windowHandle, [IntPtr]$state)
    [uint32]$windowPid = 0
    [void][R13UiaWin32]::GetWindowThreadProcessId($windowHandle, [ref]$windowPid)
    if ($pidSet.ContainsKey([int]$windowPid) -and [R13UiaWin32]::IsWindowVisible($windowHandle)) {
        $handles.Add($windowHandle)
    }
    return $true
}
[void][R13UiaWin32]::EnumWindows($callback, [IntPtr]::Zero)

function Get-Record {
    param([System.Windows.Automation.AutomationElement]$Element)
    [object]$invokePattern = $null
    [object]$valuePattern = $null
    $hasInvoke = $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)
    $hasValue = $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)
    return [ordered]@{
        processId = $Element.Current.ProcessId
        name = $Element.Current.Name
        automationId = $Element.Current.AutomationId
        controlType = $Element.Current.ControlType.ProgrammaticName
        className = $Element.Current.ClassName
        acceleratorKey = $Element.Current.AcceleratorKey
        accessKey = $Element.Current.AccessKey
        helpText = $Element.Current.HelpText
        enabled = $Element.Current.IsEnabled
        offscreen = $Element.Current.IsOffscreen
        hasInvokePattern = [bool]$hasInvoke
        hasValuePattern = [bool]$hasValue
    }
}

function Get-AllElements {
    $elements = @()
    foreach ($windowHandle in $handles.ToArray()) {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
        if ($null -eq $root) { continue }
        $elements += $root
        $descendants = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        $limit = [Math]::Min($descendants.Count, 2000)
        for ($index = 0; $index -lt $limit; $index++) {
            $elements += $descendants.Item($index)
        }
    }
    return @($elements)
}

function Select-ExactElements {
    param(
        [object[]]$Elements,
        [string]$ExactName,
        [string]$ExactControlType
    )
    return @($Elements | Where-Object {
        $_.Current.Name -eq $ExactName -and
        (!$ExactControlType -or $_.Current.ControlType.ProgrammaticName -eq "ControlType.$ExactControlType") -and
        $_.Current.IsEnabled -and
        -not $_.Current.IsOffscreen
    })
}

function Select-ButtonsContainingText {
    param(
        [object[]]$Elements,
        [string[]]$Labels
    )
    $matches = @()
    foreach ($element in $Elements) {
        if ($element.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button -or
            -not $element.Current.IsEnabled -or $element.Current.IsOffscreen) { continue }
        foreach ($label in $Labels) {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                $label
            )
            if ($element.Current.Name -eq $label -or $null -ne $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                $matches += $element
                break
            }
        }
    }
    return @($matches)
}

function Read-PrivateValue {
    if (-not $ValueFile -or -not (Test-Path -LiteralPath $ValueFile)) { throw 'Private UI value file is missing' }
    $value = (Get-Content -Raw -LiteralPath $ValueFile).Trim()
    if (-not $value -or $value.Contains("`n") -or $value.Contains("`r")) { throw 'Private UI value is invalid' }
    return $value
}

$result = [ordered]@{
    mode = $Mode
    processIds = @($pidSet.Keys | Sort-Object)
    visibleWindowCount = $handles.Count
    nodeCount = 0
    nodes = @()
    exactCount = 0
    secondaryExactCount = 0
    attempted = $false
    succeeded = $false
    error = $null
}

try {
    $elements = @(Get-AllElements)
    $result.nodeCount = $elements.Count
    if ($Mode -eq 'snapshot') {
        $records = @()
        foreach ($element in $elements) {
            try { $records += Get-Record -Element $element } catch { $records += [ordered]@{ error = $_.Exception.Message } }
        }
        $result.nodes = @($records)
    } elseif ($Mode -eq 'invoke') {
        $matches = @(Select-ExactElements -Elements $elements -ExactName $Name -ExactControlType $ControlType)
        $result.exactCount = $matches.Count
        if ($matches.Count -eq 1) {
            [object]$invoke = $null
            if ($matches[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                $result.attempted = $true
                ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
                $result.succeeded = $true
            }
        }
    } elseif ($Mode -eq 'invokeText') {
        $matches = @(Select-ButtonsContainingText -Elements $elements -Labels @($Name))
        $result.exactCount = $matches.Count
        if ($matches.Count -eq 1) {
            [object]$invoke = $null
            if ($matches[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                $result.attempted = $true
                ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
                $result.succeeded = $true
            }
        }
    } elseif ($Mode -eq 'submit') {
        $inputMatches = @(Select-ExactElements -Elements $elements -ExactName 'Message Dia…' -ExactControlType 'Edit')
        $sendMatches = @(Select-ExactElements -Elements $elements -ExactName 'Send' -ExactControlType 'Button')
        $result.exactCount = $inputMatches.Count
        $result.secondaryExactCount = $sendMatches.Count
        if ($inputMatches.Count -eq 1 -and $sendMatches.Count -eq 1) {
            [object]$value = $null
            [object]$invoke = $null
            $hasValue = $inputMatches[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value)
            $hasInvoke = $sendMatches[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)
            if ($hasValue -and $hasInvoke -and -not ([System.Windows.Automation.ValuePattern]$value).Current.IsReadOnly) {
                $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ValueBase64))
                $result.attempted = $true
                ([System.Windows.Automation.ValuePattern]$value).SetValue($text)
                ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
                $result.succeeded = $true
            }
        }
    } elseif ($Mode -eq 'onboard') {
        $email = Read-PrivateValue
        $inputs = @(Select-ExactElements -Elements $elements -ExactName 'Work email' -ExactControlType 'Edit')
        $result.exactCount = $inputs.Count
        if ($inputs.Count -eq 1) {
            [object]$value = $null
            if ($inputs[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value) -and
                -not ([System.Windows.Automation.ValuePattern]$value).Current.IsReadOnly) {
                ([System.Windows.Automation.ValuePattern]$value).SetValue($email)
                Start-Sleep -Seconds 2
                $elements = @(Get-AllElements)
                $buttons = @(Select-ButtonsContainingText -Elements $elements -Labels @('Next'))
                $result.secondaryExactCount = $buttons.Count
                if ($buttons.Count -eq 1) {
                    [object]$invoke = $null
                    if ($buttons[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                        $result.attempted = $true
                        ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
                        $result.succeeded = $true
                    }
                }
            }
        }
    } else {
        $code = Read-PrivateValue
        if ($code -notmatch '^\d{6}$') { throw 'Owned confirmation code shape mismatch' }
        $promptMatches = @($elements | Where-Object { $_.Current.Name -match '(?i)code|verification|confirm' })
        $edits = @($elements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
            $_.Current.Name -ne 'Work email' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
        })
        $result.exactCount = $edits.Count
        $result.secondaryExactCount = $promptMatches.Count
        if ($promptMatches.Count -gt 0 -and ($edits.Count -eq 1 -or $edits.Count -eq 6)) {
            $targets = if ($edits.Count -eq 1) { @($code) } else { @($code.ToCharArray() | ForEach-Object { [string]$_ }) }
            for ($index = 0; $index -lt $edits.Count; $index++) {
                [object]$value = $null
                if (-not $edits[$index].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value) -or
                    ([System.Windows.Automation.ValuePattern]$value).Current.IsReadOnly) { throw 'Code input is not writable' }
                ([System.Windows.Automation.ValuePattern]$value).SetValue($targets[$index])
            }
            $result.attempted = $true
            Start-Sleep -Seconds 2
            $elements = @(Get-AllElements)
            $buttons = @(Select-ButtonsContainingText -Elements $elements -Labels @('Next', 'Continue', 'Verify'))
            if ($buttons.Count -eq 1) {
                [object]$invoke = $null
                if ($buttons[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
                    ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
                }
            } elseif ($buttons.Count -gt 1) {
                throw 'Ambiguous code-submit control'
            }
            $result.succeeded = $true
        }
    }
} catch {
    $result.error = $_.Exception.ToString()
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -Path $OutputPath
