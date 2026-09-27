param(
    [Parameter(Mandatory = $true)]
    [string]$DiaMsix,
    [Parameter(Mandatory = $true)]
    [string]$DependencyAppx,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [string]$OwnedEmail,
    [string]$MailPassword
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
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int position);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint item, StringBuilder text, int maxCount, uint flags);
}
'@

function Get-WindowHandlesForProcess {
    param([int]$ProcessId)
    $handles = New-Object System.Collections.Generic.List[IntPtr]
    $callback = [R13Win32+EnumWindowsProc]{
        param([IntPtr]$windowHandle, [IntPtr]$state)
        [uint32]$windowPid = 0
        [void][R13Win32]::GetWindowThreadProcessId($windowHandle, [ref]$windowPid)
        if ([int]$windowPid -eq $ProcessId) { $handles.Add($windowHandle) }
        return $true
    }
    [void][R13Win32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($handles.ToArray())
}

function Convert-UiaElementToRecord {
    param([System.Windows.Automation.AutomationElement]$Element)
    try {
        [object]$invokePattern = $null
        [object]$valuePattern = $null
        $hasInvokePattern = $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)
        $hasValuePattern = $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)
        return [ordered]@{
            name = $Element.Current.Name
            automationId = $Element.Current.AutomationId
            controlType = $Element.Current.ControlType.ProgrammaticName
            className = $Element.Current.ClassName
            acceleratorKey = $Element.Current.AcceleratorKey
            accessKey = $Element.Current.AccessKey
            helpText = $Element.Current.HelpText
            enabled = $Element.Current.IsEnabled
            offscreen = $Element.Current.IsOffscreen
            hasInvokePattern = [bool]$hasInvokePattern
            hasValuePattern = [bool]$hasValuePattern
        }
    } catch {
        return [ordered]@{ error = $_.Exception.Message }
    }
}

function Get-UiaNodesForProcess {
    param([int]$ProcessId)
    $items = @()
    foreach ($windowHandle in @(Get-WindowHandlesForProcess -ProcessId $ProcessId)) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
            if ($null -eq $root) { continue }
            $items += Convert-UiaElementToRecord -Element $root
            $found = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
            $limit = [Math]::Min($found.Count, 2000)
            for ($i = 0; $i -lt $limit; $i++) {
                $element = $found.Item($i)
                $items += Convert-UiaElementToRecord -Element $element
            }
        } catch {
            $items += [ordered]@{ error = $_.Exception.Message }
        }
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
        foreach ($windowHandle in @(Get-WindowHandlesForProcess -ProcessId $pidValue)) {
            try {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
                if ($null -eq $root) { continue }
                if ($root.Current.Name -eq $Name) { $matches += $root }
                $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty,
                    $Name
                )
                $found = $root.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $nameCondition
                )
                foreach ($element in $found) {
                    $matches += $element
                }
            } catch {
            }
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
            $menuTree = @()
            if ($menuCount -gt 0) {
                for ($index = 0; $index -lt $menuCount; $index++) {
                    $label = New-Object System.Text.StringBuilder 512
                    [void][R13Win32]::GetMenuString($menu, [uint32]$index, $label, $label.Capacity, 0x400)
                    $menuItems += $label.ToString()
                }
                $menuTree = @(Get-Win32MenuTree -Menu $menu -Depth 0)
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
                menuTree = @($menuTree)
            })
        }
        return $true
    }
    [void][R13Win32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows.ToArray())
}

function Get-Win32MenuTree {
    param(
        [IntPtr]$Menu,
        [int]$Depth
    )
    if ($Menu -eq [IntPtr]::Zero -or $Depth -gt 8) { return @() }
    $entries = @()
    $count = [R13Win32]::GetMenuItemCount($Menu)
    for ($position = 0; $position -lt $count; $position++) {
        $label = New-Object System.Text.StringBuilder 512
        [void][R13Win32]::GetMenuString($Menu, [uint32]$position, $label, $label.Capacity, 0x400)
        $subMenu = [R13Win32]::GetSubMenu($Menu, $position)
        $commandId = [R13Win32]::GetMenuItemID($Menu, $position)
        $entries += [ordered]@{
            position = $position
            label = $label.ToString()
            commandId = [uint64]$commandId
            children = if ($subMenu -eq [IntPtr]::Zero) { @() } else { @(Get-Win32MenuTree -Menu $subMenu -Depth ($Depth + 1)) }
        }
    }
    return @($entries)
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

function Invoke-UiaWorker {
    param(
        [ValidateSet('snapshot', 'invoke', 'invokeText', 'submit', 'onboard', 'code')]
        [string]$Mode,
        [int[]]$ProcessIds,
        [string]$Name,
        [string]$ControlType,
        [string]$ValueBase64,
        [string]$ValueFile,
        [int]$TimeoutMilliseconds = 15000
    )
    if ($ProcessIds.Count -eq 0) {
        return [ordered]@{ mode = $Mode; timedOut = $false; visibleWindowCount = 0; nodeCount = 0; nodes = @(); exactCount = 0; secondaryExactCount = 0; attempted = $false; succeeded = $false; error = $null }
    }
    $workerPath = Join-Path $PSScriptRoot 'uia-worker.ps1'
    $workerOutput = Join-Path $env:RUNNER_TEMP ('r13-uia-worker-' + [Guid]::NewGuid().ToString('N') + '.json')
    $arguments = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $workerPath),
        '-Mode', $Mode,
        '-ProcessIds', ('"{0}"' -f (($ProcessIds | Sort-Object -Unique) -join ',')),
        '-OutputPath', ('"{0}"' -f $workerOutput)
    )
    if ($Name) { $arguments += @('-Name', ('"{0}"' -f $Name)) }
    if ($ControlType) { $arguments += @('-ControlType', $ControlType) }
    if ($ValueBase64) { $arguments += @('-ValueBase64', $ValueBase64) }
    if ($ValueFile) { $arguments += @('-ValueFile', ('"{0}"' -f $ValueFile)) }
    $workerProcess = $null
    try {
        $workerProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
        if (-not $workerProcess.WaitForExit($TimeoutMilliseconds)) {
            try { $workerProcess.Kill() } catch {}
            return [ordered]@{ mode = $Mode; timedOut = $true; visibleWindowCount = $null; nodeCount = 0; nodes = @(); exactCount = 0; secondaryExactCount = 0; attempted = $false; succeeded = $false; error = "UIA worker exceeded ${TimeoutMilliseconds}ms" }
        }
        if (-not (Test-Path -LiteralPath $workerOutput)) {
            return [ordered]@{ mode = $Mode; timedOut = $false; visibleWindowCount = $null; nodeCount = 0; nodes = @(); exactCount = 0; secondaryExactCount = 0; attempted = $false; succeeded = $false; error = "UIA worker exited $($workerProcess.ExitCode) without output" }
        }
        $parsed = Get-Content -Raw -LiteralPath $workerOutput | ConvertFrom-Json
        $parsed | Add-Member -NotePropertyName timedOut -NotePropertyValue $false
        return $parsed
    } finally {
        if (Test-Path -LiteralPath $workerOutput) {
            Remove-Item -LiteralPath $workerOutput -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-MailTmRequest {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Body,
        [string]$Bearer
    )
    $headers = @{ Accept = 'application/json'; 'User-Agent' = 'bcny-r13-owned-ui/1' }
    if ($Bearer) { $headers.Authorization = "Bearer $Bearer" }
    $parameters = @{
        Method = $Method
        Uri = "https://api.mail.tm$Path"
        Headers = $headers
        UseBasicParsing = $true
        SkipHttpErrorCheck = $true
        TimeoutSec = 30
    }
    if ($Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ($Body | ConvertTo-Json -Compress)
    }
    $response = Invoke-WebRequest @parameters
    $parsed = if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }
    return [ordered]@{ status = [int]$response.StatusCode; body = $parsed }
}

function Get-MailTmMessages {
    param([string]$Bearer)
    $response = Invoke-MailTmRequest -Method GET -Path '/messages?page=1' -Bearer $Bearer
    if ($response.status -ne 200) { throw 'mail listing status mismatch' }
    if ($response.body -is [array]) { return @($response.body) }
    if ($response.body -and $null -ne $response.body.'hydra:member') { return @($response.body.'hydra:member') }
    throw 'mail listing shape mismatch'
}

function Wait-OwnedDiaCode {
    param(
        [string]$Bearer,
        [string]$ExpectedEmail,
        [string[]]$BaselineIds
    )
    $selected = @()
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $messages = @(Get-MailTmMessages -Bearer $Bearer)
        $selected = @($messages | Where-Object {
            $_.subject -eq 'Your Dia Code' -and $_.id -and $_.id -notin $BaselineIds
        })
        if ($selected.Count -gt 1) { throw 'multiple new Dia code messages' }
        if ($selected.Count -eq 1) { break }
        if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
    }
    if ($selected.Count -ne 1) { throw 'bounded Dia code poll exhausted' }
    $messageId = [Uri]::EscapeDataString([string]$selected[0].id)
    $detailResponse = Invoke-MailTmRequest -Method GET -Path "/messages/$messageId" -Bearer $Bearer
    if ($detailResponse.status -ne 200 -or -not $detailResponse.body) { throw 'Dia code detail mismatch' }
    $detail = $detailResponse.body
    $recipientMatches = @($detail.to | Where-Object { $_.address -eq $ExpectedEmail })
    if ($detail.subject -ne 'Your Dia Code' -or $recipientMatches.Count -ne 1) { throw 'Dia code ownership mismatch' }
    $chunks = @()
    foreach ($value in @($detail.text, $detail.intro)) { if ($value -is [string]) { $chunks += $value } }
    foreach ($html in @($detail.html)) {
        if ($html -isnot [string]) { continue }
        $visible = $html -replace '(?is)<script\b.*?</script>', ' ' -replace '(?is)<style\b.*?</style>', ' ' -replace '(?s)<[^>]+>', ' '
        $chunks += [Net.WebUtility]::HtmlDecode($visible)
    }
    $codes = @([regex]::Matches(($chunks -join "`n"), '(?<!\d)\d{6}(?!\d)') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($codes.Count -ne 1) { throw 'Dia code cardinality mismatch' }
    return [string]$codes[0]
}

function Get-DiaSnapshot {
    param([string]$InstallLocation)
    $processes = @(Get-DiaProcesses -InstallLocation $InstallLocation)
    $processIds = @($processes | ForEach-Object { [int]$_.processId })
    $uiaWorker = Invoke-UiaWorker -Mode snapshot -ProcessIds $processIds
    $nodes = @($uiaWorker.nodes)
    $interesting = @($nodes | Where-Object {
        $_.name -in @('New Task', 'Task', 'Message Dia…', 'Send', 'Stop response', 'Sign in', 'Continue')
    })
    $agentServerCandidates = @(
        Get-CimInstance Win32_Process -Filter "Name='agent-server.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallLocation, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object {
            [ordered]@{ processId = [int]$_.ProcessId; parentProcessId = [int]$_.ParentProcessId; name = $_.Name; executablePath = $_.ExecutablePath; commandLine = $_.CommandLine }
        }
    )
    return [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        processes = @($processes)
        processCount = $processes.Count
        agentServerCandidates = @($agentServerCandidates)
        windows = @(Get-TopLevelWindows -ProcessIds $processIds)
        uiaWorker = $uiaWorker
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
        uiaSnapshotWorker = $null
        uiaInvokeWorker = $null
        nodes = @()
    }
    normalActivation = $null
    accountFlow = [ordered]@{
        authorizedFixtureProvided = [bool]($OwnedEmail -and $MailPassword)
        onboardingDetected = $false
        mailLoginStatus = $null
        baselineMessageCount = $null
        emailEntry = $null
        afterEmail = $null
        newOwnedCodeObserved = $false
        codeEntry = $null
        afterCode = $null
        acceptAction = $null
        finalSnapshot = $null
        signedIn = $false
        errorClass = $null
    }
    exactNewTaskControl = [ordered]@{
        count = 0
        invokeAttempted = $false
        invokeSucceeded = $false
        reason = $null
        uiaWorker = $null
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
        symmetricCleanupGate = $false
        agentHasLocalFileTools = $false
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
$mailToken = $null
$ownedCode = $null

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
    $positiveSnapshot = Invoke-UiaWorker -Mode snapshot -ProcessIds @($positiveProcess.Id)
    $result.positiveControl.uiaSnapshotWorker = $positiveSnapshot
    $positiveNodes = @($positiveSnapshot.nodes)
    $result.positiveControl.nodes = @($positiveNodes)
    $result.positiveControl.nodeCount = $positiveNodes.Count
    $positiveAction = Invoke-UiaWorker -Mode invoke -ProcessIds @($positiveProcess.Id) -Name 'R13 Positive Control' -ControlType 'Button'
    $result.positiveControl.uiaInvokeWorker = $positiveAction
    $result.positiveControl.exactButtonCount = $positiveAction.exactCount
    $result.positiveControl.invokeAttempted = $positiveAction.attempted
    if ($positiveAction.succeeded) {
        Start-Sleep -Seconds 2
        $result.positiveControl.markerObserved = Test-Path $positiveMarker
    }

    Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\TheBrowserCompany.Dia_ttt1ap7aakyb4!Dia' | Out-Null
    Start-Sleep -Seconds 15
    $result.normalActivation = Get-DiaSnapshot -InstallLocation $package.InstallLocation

    $onboardingNodes = @($result.normalActivation.uiaNodes)
    $result.accountFlow.onboardingDetected = @($onboardingNodes | Where-Object { $_.name -eq "What's your work email?" }).Count -eq 1
    if ($result.accountFlow.onboardingDetected -and $result.accountFlow.authorizedFixtureProvided) {
        try {
            $mailLogin = Invoke-MailTmRequest -Method POST -Path '/token' -Body @{ address = $OwnedEmail; password = $MailPassword }
            $result.accountFlow.mailLoginStatus = $mailLogin.status
            if ($mailLogin.status -ne 200 -or -not $mailLogin.body.token -or -not $mailLogin.body.id) { throw 'owned mail login failed' }
            $mailToken = [string]$mailLogin.body.token
            $baselineMessages = @(Get-MailTmMessages -Bearer $mailToken)
            $baselineIds = @($baselineMessages | ForEach-Object { [string]$_.id })
            $result.accountFlow.baselineMessageCount = $baselineMessages.Count

            $emailValueFile = Join-Path $env:RUNNER_TEMP ('r13-owned-email-' + [Guid]::NewGuid().ToString('N') + '.secret')
            try {
                [IO.File]::WriteAllText($emailValueFile, $OwnedEmail, [Text.Encoding]::UTF8)
                $emailAction = Invoke-UiaWorker -Mode onboard -ProcessIds @($result.normalActivation.processes | ForEach-Object { [int]$_.processId }) -ValueFile $emailValueFile -TimeoutMilliseconds 25000
                $result.accountFlow.emailEntry = $emailAction
            } finally {
                if (Test-Path -LiteralPath $emailValueFile) { Remove-Item -LiteralPath $emailValueFile -Force -ErrorAction SilentlyContinue }
            }
            if (-not $emailAction.succeeded) { throw 'owned email UI action failed' }
            Start-Sleep -Seconds 8
            $result.accountFlow.afterEmail = Get-DiaSnapshot -InstallLocation $package.InstallLocation

            $ownedCode = Wait-OwnedDiaCode -Bearer $mailToken -ExpectedEmail $OwnedEmail -BaselineIds $baselineIds
            $result.accountFlow.newOwnedCodeObserved = $true
            $codeValueFile = Join-Path $env:RUNNER_TEMP ('r13-owned-code-' + [Guid]::NewGuid().ToString('N') + '.secret')
            try {
                [IO.File]::WriteAllText($codeValueFile, $ownedCode, [Text.Encoding]::UTF8)
                $codeAction = Invoke-UiaWorker -Mode code -ProcessIds @($result.accountFlow.afterEmail.processes | ForEach-Object { [int]$_.processId }) -ValueFile $codeValueFile -TimeoutMilliseconds 25000
                $result.accountFlow.codeEntry = $codeAction
            } finally {
                if (Test-Path -LiteralPath $codeValueFile) { Remove-Item -LiteralPath $codeValueFile -Force -ErrorAction SilentlyContinue }
            }
            if (-not $codeAction.succeeded) { throw 'owned code UI action failed' }
            Start-Sleep -Seconds 12
            $result.accountFlow.afterCode = Get-DiaSnapshot -InstallLocation $package.InstallLocation

            $postCodeIds = @($result.accountFlow.afterCode.processes | ForEach-Object { [int]$_.processId })
            $acceptAction = Invoke-UiaWorker -Mode invokeText -ProcessIds $postCodeIds -Name 'Accept' -ControlType 'Button'
            $result.accountFlow.acceptAction = $acceptAction
            if ($acceptAction.exactCount -eq 1 -and $acceptAction.succeeded) { Start-Sleep -Seconds 12 }
            $result.accountFlow.finalSnapshot = Get-DiaSnapshot -InstallLocation $package.InstallLocation
            $finalNodes = @($result.accountFlow.finalSnapshot.uiaNodes)
            $result.accountFlow.signedIn = @($finalNodes | Where-Object { $_.name -eq "What's your work email?" }).Count -eq 0
        } catch {
            $result.accountFlow.errorClass = $_.Exception.GetType().Name
        }
    }

    $activeSnapshot = if ($result.accountFlow.finalSnapshot) { $result.accountFlow.finalSnapshot } elseif ($result.accountFlow.afterCode) { $result.accountFlow.afterCode } elseif ($result.accountFlow.afterEmail) { $result.accountFlow.afterEmail } else { $result.normalActivation }

    $diaProcessIds = @($activeSnapshot.processes | ForEach-Object { [int]$_.processId })
    $newTaskAction = Invoke-UiaWorker -Mode invoke -ProcessIds $diaProcessIds -Name 'New Task' -ControlType 'Button'
    $result.exactNewTaskControl.uiaWorker = $newTaskAction
    $result.exactNewTaskControl.count = $newTaskAction.exactCount
    $result.exactNewTaskControl.invokeAttempted = $newTaskAction.attempted
    $result.exactNewTaskControl.invokeSucceeded = $newTaskAction.succeeded
    if ($newTaskAction.exactCount -eq 1) {
        if ($newTaskAction.succeeded) {
            Start-Sleep -Seconds 10
            $result.afterNewTaskInvocation = Get-DiaSnapshot -InstallLocation $package.InstallLocation

            $taskNodes = @($result.afterNewTaskInvocation.uiaNodes)
            $taskInputs = @($taskNodes | Where-Object { $_.name -eq 'Message Dia…' -and $_.controlType -eq 'ControlType.Edit' -and $_.enabled -and -not $_.offscreen })
            $taskSendButtons = @($taskNodes | Where-Object { $_.name -eq 'Send' -and $_.controlType -eq 'ControlType.Button' -and $_.enabled -and -not $_.offscreen })
            $result.promptSubmission.exactInputCount = $taskInputs.Count
            $result.promptSubmission.exactSendCount = $taskSendButtons.Count
            if ($taskInputs.Count -eq 1 -and $taskSendButtons.Count -eq 1) {
                $result.promptSubmission.reason = 'Exact unsigned composer and Send control were mapped, but no symmetric task deletion/cleanup path was recovered; no prompt was entered.'
            } else {
                $result.promptSubmission.reason = if ($result.afterNewTaskInvocation.uiaWorker.timedOut) { 'The time-bounded UIA composer map timed out; no prompt was entered.' } else { 'The exact supported New Task control did not yield one unambiguous writable composer and Send button.' }
            }
        } else {
            $result.exactNewTaskControl.reason = if ($newTaskAction.timedOut) { 'The time-bounded UIA action worker timed out.' } else { 'The unique exact control did not expose InvokePattern.' }
        }
    } elseif ($newTaskAction.exactCount -eq 0) {
        $result.exactNewTaskControl.reason = if ($newTaskAction.timedOut) { 'The time-bounded UIA action worker timed out before resolving an exact New Task control.' } else { 'No exact enabled, on-screen UIA Button named New Task was exposed.' }
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
                    if (Get-Process -Id $process.processId -ErrorAction SilentlyContinue) {
                        Stop-Process -Id $process.processId -Force -ErrorAction Stop
                        $result.cleanup.diaProcessesStopped += [int]$process.processId
                    }
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
    $serializedResult = $result | ConvertTo-Json -Depth 12
    $redactionValues = @($OwnedEmail, $MailPassword, $mailToken, $ownedCode) | Where-Object { $_ }
    foreach ($secretValue in $redactionValues) {
        $serializedResult = $serializedResult.Replace([string]$secretValue, '[REDACTED]')
        $encodedValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$secretValue))
        $serializedResult = $serializedResult.Replace($encodedValue, '[REDACTED_BASE64]')
    }
    $serializedResult | Set-Content -Encoding utf8 -Path $OutputPath
}
