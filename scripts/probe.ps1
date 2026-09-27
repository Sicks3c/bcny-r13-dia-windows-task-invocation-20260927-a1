param(
    [Parameter(Mandatory = $true)]
    [string]$DiaMsix,
    [Parameter(Mandatory = $true)]
    [string]$DependencyAppx,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class R13Win32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint item, StringBuilder text, int maxCount, uint flags);
}
'@

function Get-UiaNodesForProcess {
    param([int]$ProcessId)
    $items = @()
    try {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
            $ProcessId
        )
        $found = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        $limit = [Math]::Min($found.Count, 2000)
        for ($i = 0; $i -lt $limit; $i++) {
            $element = $found.Item($i)
            try {
                [object]$invokePattern = $null
                [object]$valuePattern = $null
                $hasInvokePattern = $element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)
                $hasValuePattern = $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)
                $items += [ordered]@{
                    name = $element.Current.Name
                    automationId = $element.Current.AutomationId
                    controlType = $element.Current.ControlType.ProgrammaticName
                    className = $element.Current.ClassName
                    enabled = $element.Current.IsEnabled
                    offscreen = $element.Current.IsOffscreen
                    hasInvokePattern = [bool]$hasInvokePattern
                    hasValuePattern = [bool]$hasValuePattern
                }
            } catch {
                $items += [ordered]@{ error = $_.Exception.Message }
            }
        }
    } catch {
        $items += [ordered]@{ error = $_.Exception.Message }
    }
    return @($items)
}

function Find-ExactUiaElements {
    param(
        [int[]]$ProcessIds,
        [string]$Name
    )
    $matches = @()
    foreach ($pidValue in $ProcessIds) {
        try {
            $pidCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                $pidValue
            )
            $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                $Name
            )
            $condition = [System.Windows.Automation.AndCondition]::new($pidCondition, $nameCondition)
            $found = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                $condition
            )
            foreach ($element in $found) {
                $matches += $element
            }
        } catch {
        }
    }
    return @($matches)
}

function Get-TopLevelWindows {
    param([int[]]$ProcessIds)
    $processSet = @{}
    foreach ($pidValue in $ProcessIds) { $processSet[$pidValue] = $true }
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [R13Win32+EnumWindowsProc]{
        param([IntPtr]$windowHandle, [IntPtr]$state)
        [uint32]$windowPid = 0
        [void][R13Win32]::GetWindowThreadProcessId($windowHandle, [ref]$windowPid)
        if ($processSet.ContainsKey([int]$windowPid)) {
            $title = New-Object System.Text.StringBuilder 1024
            [void][R13Win32]::GetWindowText($windowHandle, $title, $title.Capacity)
            $className = New-Object System.Text.StringBuilder 512
            [void][R13Win32]::GetClassName($windowHandle, $className, $className.Capacity)
            $menu = [R13Win32]::GetMenu($windowHandle)
            $menuCount = if ($menu -eq [IntPtr]::Zero) { 0 } else { [R13Win32]::GetMenuItemCount($menu) }
            $menuItems = @()
            if ($menuCount -gt 0) {
                for ($index = 0; $index -lt $menuCount; $index++) {
                    $label = New-Object System.Text.StringBuilder 512
                    [void][R13Win32]::GetMenuString($menu, [uint32]$index, $label, $label.Capacity, 0x400)
                    $menuItems += $label.ToString()
                }
            }
            $windows.Add([ordered]@{
                handle = ('0x{0:x}' -f $windowHandle.ToInt64())
                processId = [int]$windowPid
                title = $title.ToString()
                className = $className.ToString()
                visible = [R13Win32]::IsWindowVisible($windowHandle)
                enabled = [R13Win32]::IsWindowEnabled($windowHandle)
                menuCount = $menuCount
                menuItems = @($menuItems)
            })
        }
        return $true
    }
    [void][R13Win32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows)
}

function Get-DiaProcesses {
    param([string]$InstallLocation)
    $matches = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='Dia.exe'" -ErrorAction SilentlyContinue)) {
        if ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($InstallLocation, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += [ordered]@{
                processId = [int]$process.ProcessId
                parentProcessId = [int]$process.ParentProcessId
                executablePath = $process.ExecutablePath
                commandLine = $process.CommandLine
            }
        }
    }
    return @($matches)
}

function Get-DiaSnapshot {
    param([string]$InstallLocation)
    $processes = @(Get-DiaProcesses -InstallLocation $InstallLocation)
    $processIds = @($processes | ForEach-Object { [int]$_.processId })
    $nodes = @()
    foreach ($pidValue in $processIds) {
        $nodes += @(Get-UiaNodesForProcess -ProcessId $pidValue)
    }
    $interesting = @($nodes | Where-Object {
        $_.name -in @('New Task', 'Task', 'Message Dia…', 'Send', 'Stop response', 'Sign in', 'Continue')
    })
    return [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        processes = @($processes)
        processCount = $processes.Count
        windows = @(Get-TopLevelWindows -ProcessIds $processIds)
        uiaNodeCount = $nodes.Count
        uiaNodes = @($nodes)
        interestingUiaNodes = @($interesting)
    }
}

$result = [ordered]@{
    schema = 'r13-dia-windows-task-invocation-v1'
    startedUtc = [DateTime]::UtcNow.ToString('o')
    runner = [ordered]@{
        osVersion = [Environment]::OSVersion.VersionString
        userInteractive = [Environment]::UserInteractive
        sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    }
    package = [ordered]@{
        expectedVersion = '0.28.0.380'
        expectedFamilyName = 'TheBrowserCompany.Dia_ttt1ap7aakyb4'
        diaSha256 = (Get-FileHash -Algorithm SHA256 $DiaMsix).Hash.ToLowerInvariant()
        dependencySha256 = (Get-FileHash -Algorithm SHA256 $DependencyAppx).Hash.ToLowerInvariant()
        hashesVerified = $false
        baselinePresent = $false
        installedFullName = $null
        installLocation = $null
    }
    positiveControl = [ordered]@{
        processId = $null
        nodeCount = 0
        exactButtonCount = 0
        invokeAttempted = $false
        markerObserved = $false
        nodes = @()
    }
    normalActivation = $null
    exactNewTaskControl = [ordered]@{
        count = 0
        invokeAttempted = $false
        invokeSucceeded = $false
        reason = $null
    }
    afterNewTaskInvocation = $null
    externalActivation = [ordered]@{
        internalUrl = 'chrome-extension://cnmkapobonpnoikggfbonmdkknnglejo/index.html#/home/task'
        osShellAttempted = $false
        osShellAccepted = $false
        osShellError = $null
        directDiaAttempted = $false
        directDiaStarted = $false
        directDiaError = $null
        afterDirectDiaSnapshot = $null
    }
    promptSubmission = [ordered]@{
        attempted = $false
        marker = $null
        markerPath = $null
        exactInputCount = 0
        exactSendCount = 0
        valueSet = $false
        sendInvoked = $false
        markerObserved = $false
        markerContentsMatched = $false
        responseSnapshot = $null
        reason = 'No task prompt is entered unless an unsigned task composer is deterministically exposed after exact supported invocation.'
    }
    errors = @()
    cleanup = [ordered]@{
        attempted = $false
        diaProcessesStopped = @()
        diaPackageRemoved = $false
        dependencyPackagesRemoved = @()
        positiveControlStopped = $false
        residualDiaPackageCount = $null
    }
}

$diaInstalledByProbe = $false
$newDependencyFullNames = @()
$positiveProcess = $null

try {
    $result.package.hashesVerified = (
        $result.package.diaSha256 -eq 'fd92a6dd178222bc687683a2353b540bd13d0ed42ff87b61124a09bd8be09407' -and
        $result.package.dependencySha256 -eq '077a3d1a5d0622bd3004dca85f5e192d6e98ec79b83d4aa06766759ea6c09c3d'
    )
    if (-not $result.package.hashesVerified) { throw 'Package hash verification failed' }

    $baselineDia = @(Get-AppxPackage -Name 'TheBrowserCompany.Dia' -ErrorAction SilentlyContinue)
    $result.package.baselinePresent = ($baselineDia.Count -gt 0)
    if ($result.package.baselinePresent) { throw 'Refusing to modify a runner with a pre-existing Dia package' }

    $dependencyBefore = @(
        Get-AppxPackage -Name 'Microsoft.VCLibs*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.PackageFullName }
    )
    Add-AppxPackage -Path $DependencyAppx
    $dependencyAfter = @(
        Get-AppxPackage -Name 'Microsoft.VCLibs*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.PackageFullName }
    )
    $newDependencyFullNames = @($dependencyAfter | Where-Object { $_ -notin $dependencyBefore })

    Add-AppxPackage -Path $DiaMsix
    $diaInstalledByProbe = $true
    $package = Get-AppxPackage -Name 'TheBrowserCompany.Dia' -ErrorAction Stop |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $result.package.installedFullName = $package.PackageFullName
    $result.package.installLocation = $package.InstallLocation
    if ($package.Version.ToString() -ne '0.28.0.380') { throw "Unexpected installed version: $($package.Version)" }

    $positiveMarker = Join-Path $env:RUNNER_TEMP 'r13-uia-positive-control-invoked.txt'
    $positiveScript = Join-Path $PSScriptRoot 'positive-control.ps1'
    $positiveProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $positiveScript), '-MarkerPath', ('"{0}"' -f $positiveMarker)
    ) -PassThru
    $result.positiveControl.processId = $positiveProcess.Id
    Start-Sleep -Seconds 3
    $positiveNodes = @(Get-UiaNodesForProcess -ProcessId $positiveProcess.Id)
    $result.positiveControl.nodes = @($positiveNodes)
    $result.positiveControl.nodeCount = $positiveNodes.Count
    $positiveButtons = @(Find-ExactUiaElements -ProcessIds @($positiveProcess.Id) -Name 'R13 Positive Control')
    $result.positiveControl.exactButtonCount = $positiveButtons.Count
    if ($positiveButtons.Count -eq 1) {
        [object]$positiveInvoke = $null
        if ($positiveButtons[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$positiveInvoke)) {
            $result.positiveControl.invokeAttempted = $true
            ([System.Windows.Automation.InvokePattern]$positiveInvoke).Invoke()
            Start-Sleep -Seconds 2
            $result.positiveControl.markerObserved = Test-Path $positiveMarker
        }
    }

    Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\TheBrowserCompany.Dia_ttt1ap7aakyb4!Dia' | Out-Null
    Start-Sleep -Seconds 15
    $result.normalActivation = Get-DiaSnapshot -InstallLocation $package.InstallLocation

    $diaProcessIds = @($result.normalActivation.processes | ForEach-Object { [int]$_.processId })
    $newTaskControls = @(Find-ExactUiaElements -ProcessIds $diaProcessIds -Name 'New Task' | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
        $_.Current.IsEnabled -and
        -not $_.Current.IsOffscreen
    })
    $result.exactNewTaskControl.count = $newTaskControls.Count
    if ($newTaskControls.Count -eq 1) {
        [object]$invoke = $null
        if ($newTaskControls[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
            $result.exactNewTaskControl.invokeAttempted = $true
            ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
            $result.exactNewTaskControl.invokeSucceeded = $true
            Start-Sleep -Seconds 10
            $result.afterNewTaskInvocation = Get-DiaSnapshot -InstallLocation $package.InstallLocation

            $taskProcessIds = @($result.afterNewTaskInvocation.processes | ForEach-Object { [int]$_.processId })
            $taskInputs = @(Find-ExactUiaElements -ProcessIds $taskProcessIds -Name 'Message Dia…' | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                $_.Current.IsEnabled -and
                -not $_.Current.IsOffscreen
            })
            $taskSendButtons = @(Find-ExactUiaElements -ProcessIds $taskProcessIds -Name 'Send' | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
                $_.Current.IsEnabled -and
                -not $_.Current.IsOffscreen
            })
            $result.promptSubmission.exactInputCount = $taskInputs.Count
            $result.promptSubmission.exactSendCount = $taskSendButtons.Count
            if ($taskInputs.Count -eq 1 -and $taskSendButtons.Count -eq 1) {
                [object]$valuePattern = $null
                [object]$sendInvoke = $null
                $hasValue = $taskInputs[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)
                $hasSendInvoke = $taskSendButtons[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$sendInvoke)
                if ($hasValue -and $hasSendInvoke -and -not ([System.Windows.Automation.ValuePattern]$valuePattern).Current.IsReadOnly) {
                    $safeToken = 'R13_TASK_MARKER_' + [Guid]::NewGuid().ToString('N')
                    $safeMarkerPath = Join-Path $env:RUNNER_TEMP ($safeToken + '.txt')
                    $safePrompt = "Create a UTF-8 text file at $safeMarkerPath containing only $safeToken, then read that same file back and reply with its exact contents. Do not access any other file, network site, account, or user data."
                    $result.promptSubmission.marker = $safeToken
                    $result.promptSubmission.markerPath = $safeMarkerPath
                    $result.promptSubmission.attempted = $true
                    ([System.Windows.Automation.ValuePattern]$valuePattern).SetValue($safePrompt)
                    $result.promptSubmission.valueSet = $true
                    ([System.Windows.Automation.InvokePattern]$sendInvoke).Invoke()
                    $result.promptSubmission.sendInvoked = $true
                    Start-Sleep -Seconds 45
                    $result.promptSubmission.markerObserved = Test-Path -LiteralPath $safeMarkerPath
                    if ($result.promptSubmission.markerObserved) {
                        $result.promptSubmission.markerContentsMatched = ((Get-Content -Raw -LiteralPath $safeMarkerPath).Trim() -eq $safeToken)
                    }
                    $result.promptSubmission.responseSnapshot = Get-DiaSnapshot -InstallLocation $package.InstallLocation
                    $result.promptSubmission.reason = 'The exact unsigned composer was exposed after the exact New Task button and received one constrained local marker task.'
                } else {
                    $result.promptSubmission.reason = 'Exact named controls appeared, but the input/send patterns were not both writable and invokable.'
                }
            } else {
                $result.promptSubmission.reason = 'The exact supported New Task control did not yield one unambiguous writable composer and Send button.'
            }
        } else {
            $result.exactNewTaskControl.reason = 'The unique exact control did not expose InvokePattern.'
        }
    } elseif ($newTaskControls.Count -eq 0) {
        $result.exactNewTaskControl.reason = 'No exact enabled, on-screen UIA Button named New Task was exposed.'
    } else {
        $result.exactNewTaskControl.reason = 'More than one exact target was exposed; refusing ambiguous invocation.'
    }

    $result.externalActivation.osShellAttempted = $true
    try {
        Start-Process -FilePath $result.externalActivation.internalUrl -ErrorAction Stop | Out-Null
        $result.externalActivation.osShellAccepted = $true
    } catch {
        $result.externalActivation.osShellError = $_.Exception.Message
    }
    Start-Sleep -Seconds 3

    $diaExe = Join-Path $package.InstallLocation 'Dia.exe'
    $result.externalActivation.directDiaAttempted = $true
    try {
        Start-Process -FilePath $diaExe -ArgumentList @($result.externalActivation.internalUrl) -ErrorAction Stop | Out-Null
        $result.externalActivation.directDiaStarted = $true
    } catch {
        $result.externalActivation.directDiaError = $_.Exception.Message
    }
    Start-Sleep -Seconds 10
    $result.externalActivation.afterDirectDiaSnapshot = Get-DiaSnapshot -InstallLocation $package.InstallLocation

    if (-not $result.promptSubmission.attempted -and -not $result.exactNewTaskControl.invokeSucceeded) {
        $result.promptSubmission.reason = 'Unsigned task composer was not deterministically reachable through the exact supported invocation paths.'
    }
} catch {
    $result.errors += $_.Exception.ToString()
} finally {
    $result.cleanup.attempted = $true
    try {
        if ($result.package.installLocation) {
            foreach ($process in @(Get-DiaProcesses -InstallLocation $result.package.installLocation)) {
                try {
                    Stop-Process -Id $process.processId -Force -ErrorAction Stop
                    $result.cleanup.diaProcessesStopped += [int]$process.processId
                } catch {
                    $result.errors += "Dia process cleanup: $($_.Exception.Message)"
                }
            }
        }
        if ($positiveProcess -and -not $positiveProcess.HasExited) {
            Stop-Process -Id $positiveProcess.Id -Force -ErrorAction SilentlyContinue
            $result.cleanup.positiveControlStopped = $true
        } elseif ($positiveProcess) {
            $result.cleanup.positiveControlStopped = $true
        }
        if ($result.promptSubmission.markerPath -and (Test-Path -LiteralPath $result.promptSubmission.markerPath)) {
            Remove-Item -LiteralPath $result.promptSubmission.markerPath -Force -ErrorAction SilentlyContinue
        }
        if ($diaInstalledByProbe -and $result.package.installedFullName) {
            Remove-AppxPackage -Package $result.package.installedFullName -ErrorAction Stop
            $result.cleanup.diaPackageRemoved = $true
        }
        foreach ($dependencyFullName in $newDependencyFullNames) {
            try {
                Remove-AppxPackage -Package $dependencyFullName -ErrorAction Stop
                $result.cleanup.dependencyPackagesRemoved += $dependencyFullName
            } catch {
                $result.errors += "Dependency cleanup ${dependencyFullName}: $($_.Exception.Message)"
            }
        }
        $result.cleanup.residualDiaPackageCount = @(
            Get-AppxPackage -Name 'TheBrowserCompany.Dia' -ErrorAction SilentlyContinue
        ).Count
    } catch {
        $result.errors += "Cleanup: $($_.Exception.ToString())"
    }
    $result.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $outputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $result | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 -Path $OutputPath
}
