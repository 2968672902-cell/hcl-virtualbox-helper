param([switch]$Worker, [string]$ExchangeDir = '', [string]$HclPath = '', [int]$ParentId = 0)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-Notice([string]$text, [string]$title = 'HCL 启动助手') {
    [void][Windows.Forms.MessageBox]::Show($text, $title, 'OK', 'Information')
}
function Get-GameProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(League of Legends|LeagueClient|cs2|csgo|perfectworldarena|PerfectWorldPlatform|VALORANT-Win64-Shipping)\.exe$'
    })
}
function Get-ExistingHclOrVm {
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(H3C Cloud Lab|SimwareClient|VBoxHeadless|VirtualBoxVM)\.exe$'
    })
}
function Find-Hcl {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($item in @(Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'H3C Cloud Lab|HCL' })) {
            if ($item.InstallLocation) { $candidates.Add((Join-Path $item.InstallLocation 'H3C Cloud Lab.exe')) }
        }
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        foreach ($rel in @('HCL\H3C Cloud Lab.exe','Program Files\H3C\HCL\H3C Cloud Lab.exe','Program Files (x86)\H3C\HCL\H3C Cloud Lab.exe','app\apps\HCL\H3C Cloud Lab.exe')) {
            $candidates.Add((Join-Path $drive.Root $rel))
        }
    }
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { (Get-Item -LiteralPath $_).FullName } | Select-Object -Unique)
    if ($found.Count -eq 1) { return $found[0] }
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = '请选择 HCL 安装目录中的 H3C Cloud Lab.exe'
    $dialog.Filter = 'HCL 主程序 (H3C Cloud Lab.exe)|H3C Cloud Lab.exe'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '未选择 HCL 主程序。' }
    if ([IO.Path]::GetFileName($dialog.FileName) -ine 'H3C Cloud Lab.exe') { throw '请选择 H3C Cloud Lab.exe。' }
    return $dialog.FileName
}
function Set-Signal([string]$name, [string]$value) {
    Set-Content -LiteralPath (Join-Path $ExchangeDir $name) -Value $value -Encoding UTF8 -ErrorAction Stop
}
function Get-ExpectedProcesses([string]$base) {
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(H3C Cloud Lab|SimwareClient)\.exe$' -and $_.ExecutablePath -and
        ([IO.Path]::GetDirectoryName($_.ExecutablePath) -ieq $base)
    })
}

if ($Worker) {
    $changed = $false
    $workerMessage = $null
    $workerMutex = $null
    $workerLock = $false
    try {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '未获得管理员权限。' }
        $workerMutex = New-Object Threading.Mutex($false, 'Local\HCLTempDriverWorker')
        $workerLock = $workerMutex.WaitOne(0)
        if (-not $workerLock) { throw '另一个启动助手仍在运行。' }
        if (Get-GameProcesses) { throw '检测到游戏或游戏平台仍在运行，请先退出。' }
        if (Get-ExistingHclOrVm) { throw '检测到 HCL 或 VirtualBox 虚拟机正在运行，请先正常关闭。' }
        $driver = Get-CimInstance Win32_SystemDriver -Filter "Name='MessageTransfer'" -ErrorAction Stop
        if ($driver -and $driver.State -eq 'Running') {
            if ($driver.StartMode -eq 'Disabled') { throw 'MessageTransfer 已禁止启动；为确保可以恢复，助手不会停止它。' }
            $changed = $true
            & sc.exe stop MessageTransfer | Out-Null
            for ($i=0; $i -lt 15; $i++) {
                if ((Get-CimInstance Win32_SystemDriver -Filter "Name='MessageTransfer'").State -eq 'Stopped') { break }
                Start-Sleep -Seconds 1
            }
            if ((Get-CimInstance Win32_SystemDriver -Filter "Name='MessageTransfer'").State -ne 'Stopped') { throw '无法暂时停止 MessageTransfer 驱动。' }
        } elseif ($driver -and $driver.State -ne 'Stopped') { throw '驱动正处于切换状态，请稍后重试。' }
        Set-Signal 'ready.txt' 'ready'
        $launchSignal = Join-Path $ExchangeDir 'launching.txt'
        $cancelSignal = Join-Path $ExchangeDir 'cancel.txt'
        $launchRequested = $false
        for ($i=0; $i -lt 120; $i++) {
            if (Test-Path -LiteralPath $cancelSignal) { throw '启动已取消。' }
            if (Test-Path -LiteralPath $launchSignal) { $launchRequested = $true; break }
            if (-not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $launchSignal) { $launchRequested = $true; break }
                throw '启动助手意外退出。'
            }
            Start-Sleep -Seconds 1
        }
        if (-not $launchRequested) { throw '等待 HCL 启动超时。' }
        $base = [IO.Path]::GetDirectoryName($HclPath)
        $client = $null
        $uncertainWait = 0
        while (-not $client) {
            if (Test-Path -LiteralPath $cancelSignal) { throw 'HCL 启动已取消。' }
            $matches = @(Get-ExpectedProcesses $base | Where-Object { $_.Name -ieq 'SimwareClient.exe' })
            if ($matches.Count -gt 1) { throw '检测到多个 HCL 客户端，无法安全监控。' }
            if ($matches.Count -eq 1) { $client = $matches[0]; break }
            # While the parent is waiting for UAC, it may legitimately take any amount of time.
            # After a launch call returns, or the parent unexpectedly dies, allow three minutes
            # for the client. On uncertainty leave the driver stopped and request manual recovery.
            if ((Test-Path -LiteralPath (Join-Path $ExchangeDir 'start-returned.txt')) -or
                -not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) {
                $uncertainWait++
                if ($uncertainWait -ge 180) {
                    $wasChanged = $changed
                    $changed = $false
                    if ($wasChanged) { throw '无法确认 HCL 是否仍在启动；驱动暂未恢复。请关闭 HCL 和所有虚拟机，再用管理员命令提示符运行 sc.exe start MessageTransfer 并用 sc.exe query MessageTransfer 核对状态。手动启动的驱动重启后不一定自动恢复。' }
                    throw '无法确认 HCL 是否仍在启动，请关闭 HCL 并检查安装。助手没有更改驱动状态。'
                }
            }
            Start-Sleep -Seconds 1
        }
        Set-Signal 'client.txt' ([string]$client.ProcessId)
        while (Get-Process -Id $client.ProcessId -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
        for ($i=0; $i -lt 30; $i++) {
            if (-not (Get-ExistingHclOrVm)) { break }
            Start-Sleep -Seconds 1
        }
        if (Get-ExistingHclOrVm) { $changed = $false; throw '其他 HCL 或虚拟机仍在运行，驱动暂未恢复。请全部关闭后用管理员命令提示符运行 sc.exe start MessageTransfer，并用 sc.exe query MessageTransfer 核对状态。手动启动的驱动重启后不一定自动恢复。' }
    } catch {
        $workerMessage = $_.Exception.Message
        try { Set-Signal 'error.txt' $workerMessage } catch {}
    } finally {
        if ($changed) {
            try {
                if (Get-ExistingHclOrVm) { throw '检测到 HCL 或虚拟机仍在运行。' }
                & sc.exe start MessageTransfer | Out-Null
                Start-Sleep -Seconds 2
                if ((Get-CimInstance Win32_SystemDriver -Filter "Name='MessageTransfer'" -ErrorAction Stop).State -ne 'Running') { throw '驱动未处于运行状态。' }
            } catch {
                $workerMessage = ($workerMessage + "`n完美世界驱动未能自动恢复。请关闭 HCL 和虚拟机，在管理员命令提示符运行 sc.exe start MessageTransfer，再用 sc.exe query MessageTransfer 核对状态。手动启动的驱动重启后不一定自动恢复。")
            }
        }
        try { Set-Signal 'done.txt' 'done' } catch {}
        if ($workerMutex) { if ($workerLock) { $workerMutex.ReleaseMutex() }; $workerMutex.Dispose() }
        if ($workerMessage) { Show-Notice $workerMessage 'HCL 启动助手 - 提示' }
    }
    return
}

$parentMutex = $null
$parentLock = $false
try {
    $parentMutex = New-Object Threading.Mutex($false, 'Local\HCLTempDriverParent')
    $parentLock = $parentMutex.WaitOne(0)
    if (-not $parentLock) { throw '启动助手已在运行，请勿重复启动。' }
    $otherWorker = $null
    try { $otherWorker = [Threading.Mutex]::OpenExisting('Local\HCLTempDriverWorker') } catch [Threading.WaitHandleCannotBeOpenedException] {}
    if ($otherWorker) { $otherWorker.Dispose(); throw '启动助手后台仍在运行，请先关闭 HCL。' }
    if (Get-GameProcesses) { throw '检测到游戏或游戏平台仍在运行，请先退出。' }
    if (Get-ExistingHclOrVm) { throw '检测到 HCL 或 VirtualBox 虚拟机正在运行，请先正常关闭。' }
    $chosen = Find-Hcl
    if (-not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($chosen)) 'SimwareClient.exe') -PathType Leaf)) { throw '所选目录缺少 SimwareClient.exe，请重新选择完整的 HCL 安装目录。' }
    Show-Notice '使用 HCL 期间将暂时停止完美世界 MessageTransfer 驱动；正常关闭 HCL 后会恢复其原来的运行状态。请退出所有相关游戏和虚拟机，使用期间不要启动相关游戏。接下来请允许管理员授权。'
    $exchange = Join-Path ([IO.Path]::GetTempPath()) ('hcl-helper-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $exchange -ItemType Directory | Out-Null
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $PSCommandPath + '"'),'-Worker','-ExchangeDir',('"' + $exchange + '"'),'-HclPath',('"' + $chosen + '"'),'-ParentId',"$PID")
    $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $args -PassThru
    $ready = Join-Path $exchange 'ready.txt'
    for ($i=0; $i -lt 60 -and -not (Test-Path -LiteralPath $ready) -and -not $workerProcess.HasExited; $i++) { Start-Sleep -Seconds 1; $workerProcess.Refresh() }
    if (-not (Test-Path -LiteralPath $ready)) { throw '后台准备未完成，HCL 未启动。' }
    if (Get-GameProcesses) { Set-Content -LiteralPath (Join-Path $exchange 'cancel.txt') -Value 'cancel'; throw '检测到游戏已启动，已取消。' }
    if (Get-ExistingHclOrVm) { Set-Content -LiteralPath (Join-Path $exchange 'cancel.txt') -Value 'cancel'; throw '检测到 HCL 或虚拟机已启动，已取消。' }
    Set-Content -LiteralPath (Join-Path $exchange 'launching.txt') -Value 'launch' -Encoding ASCII
    try {
        Start-Process -FilePath $chosen -WorkingDirectory ([IO.Path]::GetDirectoryName($chosen)) | Out-Null
        Set-Content -LiteralPath (Join-Path $exchange 'start-returned.txt') -Value 'returned' -Encoding ASCII
    }
    catch { Set-Content -LiteralPath (Join-Path $exchange 'cancel.txt') -Value 'cancel'; throw }
    $workerProcess.WaitForExit()
} catch { Show-Notice ('启动失败：' + $_.Exception.Message) 'HCL 启动助手 - 错误' }
finally { if ($parentMutex) { if ($parentLock) { $parentMutex.ReleaseMutex() }; $parentMutex.Dispose() } }
