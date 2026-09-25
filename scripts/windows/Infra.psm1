Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:NativeFailureLog = $null

function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value) {
    # WSL's initial dispatcher does not strip quotes from flags/target names.
    # Quote only when needed; --exec payloads still use CommandLineToArgvW.
    if ($Value -match '^[^\s"]+$') { return $Value }
    # CommandLineToArgvW/CRT quoting, including empty args and trailing slashes.
    '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @(), [int]$Timeout = 300,
          [switch]$Unicode, [int[]]$AllowedExitCodes = @(0))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $encoding = New-Object Text.UTF8Encoding($false)
    if ($Unicode) { $encoding = [Text.Encoding]::Unicode }
    $info.StandardOutputEncoding = $encoding
    $info.StandardErrorEncoding = $encoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Timeout * 1000)) {
            # Kill the process tree so a timed-out provisioner cannot outlive its lock.
            & "$env:SystemRoot/System32/taskkill.exe" /PID $process.Id /T /F *> $null
            throw "Native operation timed out: $([IO.Path]::GetFileName($File)); inspect ownership before retry."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($AllowedExitCodes -notcontains $process.ExitCode) {
            $hint = 'Output suppressed (may contain secrets).'
            if ($script:NativeFailureLog) {
                [IO.File]::WriteAllText($script:NativeFailureLog, ($output + "`n" + $errorOutput), (New-Object Text.UTF8Encoding($false)))
                $hint = "Inspect private .local/$([IO.Path]::GetFileName($script:NativeFailureLog)); do not publish its contents."
            }
            throw "Native operation failed: $([IO.Path]::GetFileName($File)) exit $($process.ExitCode). $hint"
        }
        [pscustomobject]@{ Text = $output; ExitCode = $process.ExitCode }
    } finally { $process.Dispose() }
}

function ConvertFrom-WslList([string]$Text) {
    @($Text.Replace([string][char]0, '').TrimStart([char]0xfeff) -split '[\r\n]+' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-CanonicalPath([string]$Path) {
    if ($Path.StartsWith('\\?\')) { $Path = $Path.Substring(4) }
    [IO.Path]::GetFullPath($Path).TrimEnd('\', '/').ToLowerInvariant()
}

function Protect-Directory([string]$Path, [switch]$AllowSystem) {
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    if ($AllowSystem) {
        # WSL import/storage requires SYSTEM on the VHD directory, not on state.
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $systemRule = New-Object Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($systemRule)
    }
    [IO.Directory]::SetAccessControl($Path, $acl)
}

function Get-InfraContext([string]$Root) {
    $versions = Get-Content -LiteralPath (Join-Path $Root 'versions.json') -Raw | ConvertFrom-Json
    $instanceHome = Join-Path $env:LOCALAPPDATA 'infra'
    [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root); Home = $instanceHome
        Install = Join-Path $instanceHome 'wsl'; Record = Join-Path $instanceHome 'owner.json'
        Lock = Join-Path $instanceHome 'instance.lock'; Local = Join-Path $Root '.local'
        Versions = $versions
        Tofu = Join-Path $Root ".local/tools/opentofu-$($versions.opentofu.version)/tofu.exe"
        Image = Join-Path $Root '.local/downloads/ubuntu-rootfs.tar.gz'
    }
}

function Enter-InstanceLock([string]$Path) {
    try { [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'Read') }
    catch { throw 'Another infra operation holds the instance lock.' }
}

function Invoke-WithInstanceLock($Context, [scriptblock]$Body, [switch]$Bridge) {
    Protect-Directory $Context.Home
    if ($Bridge -and $Context.PSObject.Properties['Local']) {
        Protect-Directory $Context.Local
        $script:NativeFailureLog = Join-Path $Context.Local 'native-bridge-error.log'
    }
    # A wrapper holds the lock across tofu + guest convergence. Only its provisioner
    # inherits this lease; direct bridge/raw tofu calls acquire their own lock.
    if ($Bridge -and $env:INFRA_LOCK_LEASE) {
        $reader = [IO.File]::Open($Context.Lock, 'Open', 'Read', 'ReadWrite')
        try {
            $stream = New-Object IO.StreamReader($reader)
            $lease = $stream.ReadToEnd()
        } finally { $reader.Dispose() }
        if ($lease -cne $env:INFRA_LOCK_LEASE) { throw 'Invalid instance lock lease.' }
        $probe = $null
        try { $probe = [IO.File]::Open($Context.Lock, 'Open', 'ReadWrite', 'Read') } catch [IO.IOException] { }
        if ($probe) { $probe.Dispose(); throw 'Expired instance lock lease.' }
        & $Body
        return
    }
    $lock = Enter-InstanceLock $Context.Lock
    $old = $env:INFRA_LOCK_LEASE
    try {
        $env:INFRA_LOCK_LEASE = [guid]::NewGuid().ToString()
        $bytes = [Text.Encoding]::UTF8.GetBytes($env:INFRA_LOCK_LEASE)
        $lock.SetLength(0); $lock.Write($bytes, 0, $bytes.Length); $lock.Flush()
        & $Body
    } finally { $env:INFRA_LOCK_LEASE = $old; $lock.Dispose() }
}

function Get-LiveRegistration {
    $items = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $value = Get-ItemProperty $_.PSPath
            if ($value.DistributionName -ceq 'infra') {
                [pscustomobject]@{ guid = $_.PSChildName; basePath = $value.BasePath }
            }
        })
    if ($items.Count -gt 1) { throw 'Ambiguous infra registration.' }
    if ($items.Count -eq 1) { $items[0] }
}

function Read-Owner($Context) {
    if (Test-Path -LiteralPath $Context.Record) { Get-Content -LiteralPath $Context.Record -Raw | ConvertFrom-Json }
}

function Write-Owner($Context, $Record) {
    $temp = "$($Context.Record).tmp"
    [IO.File]::WriteAllText($temp, ($Record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Context.Record) {
        $backup = "$($Context.Record).bak"
        [IO.File]::Replace($temp, $Context.Record, $backup)
        [IO.File]::Delete($backup)
    }
    else { [IO.File]::Move($temp, $Context.Record) }
}

function Assert-Ownership($Record, $Live, [string]$Owner, [string]$Install, [string]$ImageHash) {
    if (-not $Record) { throw 'Missing ownership record; foreign targets are never adopted.' }
    if ($Record.phase -ne 'committed') { throw 'Incomplete preparing ownership; manual diagnosis required.' }
    if (-not $Live) { throw 'Owned registration is missing; no automatic recreation.' }
    if ($Record.name -cne 'infra' -or $Record.owner -cne $Owner -or $Record.guid -cne $Live.guid -or
        (Get-CanonicalPath $Record.basePath) -cne (Get-CanonicalPath $Live.basePath) -or
        (Get-CanonicalPath $Record.basePath) -cne (Get-CanonicalPath $Install) -or $Record.imageHash -cne $ImageHash) {
        throw 'Ownership identity mismatch; mutation refused.'
    }
}

function Assert-DestroyConfirmation([string]$Confirmation) {
    if ($Confirmation -cne 'infra') { throw 'Destroy requires exact confirmation: infra.' }
}

function Assert-Checksum([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) { throw 'SHA256 checksum mismatch.' }
}

function Invoke-Wsl([string[]]$Arguments, [int]$Timeout = 300, [switch]$Unicode, [int[]]$AllowedExitCodes = @(0)) {
    Invoke-Native "$env:SystemRoot/System32/wsl.exe" $Arguments -Timeout $Timeout -Unicode:$Unicode -AllowedExitCodes $AllowedExitCodes
}

function Invoke-Guest([string[]]$Arguments, [int]$Timeout = 300, [int[]]$AllowedExitCodes = @(0)) {
    Invoke-Wsl (@('--distribution', 'infra', '--user', 'root', '--exec') + $Arguments) -Timeout $Timeout -AllowedExitCodes $AllowedExitCodes
}

function Assert-GuestMarker($Record) {
    $text = (Invoke-Guest @('/bin/cat', '/etc/infra-owner.json')).Text
    $marker = $text | ConvertFrom-Json
    foreach ($key in @('owner', 'guid', 'basePath', 'imageHash', 'name')) {
        if ($marker.$key -cne $Record.$key) { throw 'Guest ownership marker mismatch.' }
    }
}

function Get-OwnedRecord($Context, [string]$Owner) {
    $record = Read-Owner $Context
    Assert-Ownership $record (Get-LiveRegistration) $Owner $Context.Install $Context.Versions.ubuntu.sha256
    $record
}

function Invoke-Lifecycle($Context, [string]$Action, [string]$Owner, [string]$ImageHash) {
    if ($ImageHash -cne $Context.Versions.ubuntu.sha256) { throw 'Image configuration changed; explicit migration required.' }
    if ($Action -eq 'Destroy') {
        Assert-DestroyConfirmation $env:INFRA_DESTROY_CONFIRM
        $record = Get-OwnedRecord $Context $Owner
        Assert-GuestMarker $record
        [void](Invoke-Wsl @('--unregister', 'infra'))
        if (Get-LiveRegistration) { throw 'Registration remains after unregister.' }
        if (Test-Path -LiteralPath $Context.Install) { [IO.Directory]::Delete($Context.Install, $false) }
        Remove-Item -LiteralPath $Context.Record
        return
    }
    $record = Read-Owner $Context
    $live = Get-LiveRegistration
    if ($record -or $live) {
        Assert-Ownership $record $live $Owner $Context.Install $ImageHash
        Assert-GuestMarker $record
        return
    }
    if (Test-Path -LiteralPath $Context.Install) { throw 'Unrecorded install directory; no automatic reuse.' }
    Assert-Checksum $Context.Image $ImageHash
    $record = [pscustomobject]@{ phase='preparing'; name='infra'; owner=$Owner; guid=''; basePath=(Get-CanonicalPath $Context.Install); imageHash=$ImageHash }
    Write-Owner $Context $record
    Protect-Directory $Context.Install -AllowSystem
    [void](Invoke-Wsl @('--import', 'infra', $Context.Install, $Context.Image, '--version', '2') -Timeout 900 -Unicode)
    $live = Get-LiveRegistration
    if (-not $live -or (Get-CanonicalPath $live.basePath) -cne $record.basePath) { throw 'Imported registration mismatch; preparing record retained.' }
    $record.guid = $live.guid
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress)))
    [void](Invoke-Guest @('/bin/bash', '-c', 'set -euo pipefail; umask 077; test ! -e /etc/infra-owner.json; printf %s "$1" | base64 -d > /etc/infra-owner.json', 'infra', $payload))
    Assert-GuestMarker $record
    $record.phase = 'committed'
    Write-Owner $Context $record
}

function Receive-PinnedFile($Pin, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { Assert-Checksum $Destination $Pin.sha256; return }
    [void][IO.Directory]::CreateDirectory((Split-Path $Destination -Parent))
    $temp = "$Destination.partial"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Pin.url -OutFile $temp -TimeoutSec 900
        Assert-Checksum $temp $Pin.sha256
        Move-Item -LiteralPath $temp -Destination $Destination
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Assert-Tofu($Context) {
    $zip = Join-Path $Context.Local 'downloads/opentofu.zip'
    if (-not (Test-Path -LiteralPath $Context.Tofu) -or -not (Test-Path -LiteralPath $zip)) { throw 'Run Bootstrap to install the pinned project-local OpenTofu.' }
    Assert-Checksum $zip $Context.Versions.opentofu.sha256
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $stream = $archive.GetEntry('tofu.exe').Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $sha.Dispose() }
        Assert-Checksum $Context.Tofu $hash
    } finally { $archive.Dispose() }
}

function Invoke-Tofu($Context, [string[]]$Arguments) {
    Invoke-Native $Context.Tofu (@("-chdir=$($Context.Root)/environments/windows") + $Arguments) -Timeout 2400
}

function Initialize-Tofu($Context) {
    Assert-Tofu $Context
    $env:TF_DATA_DIR = Join-Path $Context.Local 'tofu-data'
    $env:TF_IN_AUTOMATION = '1'
    Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_CLI_ARGS*' -or $_.Name -like 'TF_VAR_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    [void](Invoke-Tofu $Context @('init', '-input=false', "-backend-config=path=$($Context.Local)/terraform.tfstate"))
}

function Get-StateOwner($Context) {
    if (Test-Path -LiteralPath (Join-Path $Context.Local 'terraform.tfstate')) {
        return (Invoke-Tofu $Context @('output', '-raw', 'owner_id')).Text.Trim()
    }
    ''
}

function Assert-LiveState($Context, [string]$Owner) {
    $record = Read-Owner $Context; $live = Get-LiveRegistration
    if ($record -or $live -or $Owner) {
        Assert-Ownership $record $live $Owner $Context.Install $Context.Versions.ubuntu.sha256
    }
}

function New-LifecyclePlan($Context, [switch]$Destroy) {
    $plan = Join-Path $Context.Local 'lifecycle.tfplan'
    $arguments = @('plan', '-input=false', "-out=$plan")
    if ($Destroy) { $arguments += '-destroy' }
    [void](Invoke-Tofu $Context $arguments)
    $json = (Invoke-Tofu $Context @('show', '-json', $plan)).Text | ConvertFrom-Json
    if (-not $Destroy -and $json.PSObject.Properties['resource_changes']) {
        foreach ($change in $json.resource_changes) {
            if ($change.change.actions -contains 'delete') { throw 'Apply/Plan refuses deletion or replacement. Use explicit Destroy after review.' }
        }
    }
    $plan
}

function Start-OwnedKeeper($Context, $Record) {
    # systemd services alone do not keep a WSL instance alive. Hold one explicit
    # client session; Stop/Destroy terminate only infra, which also ends this client.
    $path = Join-Path $Context.Home 'keeper.json'
    if (Test-Path -LiteralPath $path) {
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $existing = Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
        if ($existing -and $existing.StartTime.ToUniversalTime().ToString('o') -ceq $saved.started) {
            if ($saved.owner -cne $Record.owner -or $saved.guid -cne $Record.guid -or $existing.ProcessName -ine 'wsl') {
                throw 'Live keeper identity mismatch; no process was stopped or adopted.'
            }
            return
        }
    }
    $process = Start-Process -FilePath "$env:SystemRoot/System32/wsl.exe" `
        -ArgumentList '--distribution infra --user root --exec /usr/bin/sleep infinity' `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Context.Home 'keeper.stdout.log') `
        -RedirectStandardError (Join-Path $Context.Home 'keeper.stderr.log')
    try {
        Start-Sleep -Milliseconds 300
        $process.Refresh()
        if ($process.HasExited) { throw 'WSL keeper exited; inspect private keeper.stderr.log.' }
        $saved = [pscustomobject]@{owner=$Record.owner;guid=$Record.guid;pid=$process.Id;started=$process.StartTime.ToUniversalTime().ToString('o')}
        [IO.File]::WriteAllText($path, ($saved | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } finally { $process.Dispose() }
}

function Invoke-GuestHandoff($Context, [string]$Owner, [string]$Action) {
    $scriptName = "$($Action.ToLowerInvariant()).sh"
    if (-not (Test-Path -LiteralPath (Join-Path $Context.Root "scripts/guest/$scriptName"))) {
        throw "Guest implementation missing: scripts/guest/$scriptName. Complete U2 before $Action."
    }
    $record = Get-OwnedRecord $Context $Owner
    Assert-GuestMarker $record
    Start-OwnedKeeper $Context $record
    if ($Action -eq 'Apply') {
        foreach ($required in @('ansible', 'config', 'scripts/guest')) {
            if (-not (Test-Path -LiteralPath (Join-Path $Context.Root $required))) { throw "Guest input missing: $required" }
        }
        $archive = Join-Path $Context.Local 'guest-input.tar'
        $inputs = @('ansible', 'config', 'versions.json', 'scripts/guest')
        if (Test-Path -LiteralPath (Join-Path $Context.Root 'examples/smoke')) { $inputs += 'examples/smoke' }
        [void](Invoke-Native "$env:SystemRoot/System32/tar.exe" (@('-cf', $archive, '-C', $Context.Root) + $inputs))
        $linuxArchive = (Invoke-Guest @('/usr/bin/wslpath', '-a', '-u', $archive)).Text.Trim()
        [void](Invoke-Guest @('/usr/bin/timeout', '--kill-after=10s', '240s', '/bin/bash', '-c', 'set -euo pipefail; umask 077; mkdir -p /opt/infra; tar -xf "$1" -C /opt/infra', 'infra', $linuxArchive))
    }
    [void](Invoke-Guest @('/usr/bin/timeout', '--kill-after=30s', '2100s', '/bin/bash', "/opt/infra/scripts/guest/$scriptName", '--root', '/opt/infra', '--owner-id', $Owner) -Timeout 2200)
    if ($Action -eq 'Apply') {
        $destination = (Invoke-Guest @('/usr/bin/wslpath', '-a', '-u', (Join-Path $Context.Local 'kubeconfig'))).Text.Trim()
        [void](Invoke-Guest @('/usr/bin/timeout', '--kill-after=10s', '240s', '/bin/bash', '-c', 'set -euo pipefail; test -s /opt/infra/.local/kubeconfig; chmod 600 /opt/infra/.local/kubeconfig; cp /opt/infra/.local/kubeconfig "$1"', 'infra', $destination))
    }
}

function Invoke-InfraCommand($Context, [string]$Command, [string]$ConfirmName) {
    $previous = $env:INFRA_DESTROY_CONFIRM
    try {
        $env:INFRA_DESTROY_CONFIRM = $null
        if ($Command -eq 'Destroy') { Assert-DestroyConfirmation $ConfirmName; $env:INFRA_DESTROY_CONFIRM = $ConfirmName }
        Invoke-WithInstanceLock $Context {
            Protect-Directory $Context.Local
            $script:NativeFailureLog = Join-Path $Context.Local 'native-error.log'
            if ($Command -eq 'Bootstrap') {
                Receive-PinnedFile $Context.Versions.ubuntu $Context.Image
                $zip = Join-Path $Context.Local 'downloads/opentofu.zip'
                Receive-PinnedFile $Context.Versions.opentofu $zip
                $tools = Split-Path $Context.Tofu -Parent
                if (-not (Test-Path -LiteralPath $Context.Tofu)) { Expand-Archive -LiteralPath $zip -DestinationPath $tools }
                Assert-Tofu $Context
                Write-Host 'Pinned downloads and OpenTofu verified. No WSL target changed.'
                return
            }
            if ($Command -eq 'Doctor') {
                $record = Read-Owner $Context; $live = Get-LiveRegistration
                if (-not $record -and -not $live) { Write-Host 'absent'; return }
                if (-not $record) { throw 'Missing ownership record; foreign target.' }
                Assert-Ownership $record $live $record.owner $Context.Install $Context.Versions.ubuntu.sha256
                $running = ConvertFrom-WslList (Invoke-Wsl @('--list', '--running', '--quiet') -Unicode).Text
                if ($running -cnotcontains 'infra') { Write-Host 'stopped (guest marker/readiness not inspected)'; return }
                Assert-GuestMarker $record
                $result = Invoke-Guest @('/usr/bin/timeout', '--kill-after=10s', '240s', '/bin/bash', '-c', 'if test ! -f /opt/infra/scripts/guest/doctor.sh; then exit 3; fi; exec /bin/bash /opt/infra/scripts/guest/doctor.sh --root /opt/infra --owner-id "$1"', 'infra', $record.owner) -AllowedExitCodes @(0,3,4)
                switch ($result.ExitCode) { 0 { Write-Host 'ready' }; 3 { Write-Host 'unconfigured' }; 4 { Write-Host 'unready' } }
                return
            }
            Initialize-Tofu $Context
            $owner = Get-StateOwner $Context
            Assert-LiveState $Context $owner
            if ($Command -in @('Plan', 'Apply', 'Destroy')) {
                $plan = New-LifecyclePlan $Context -Destroy:($Command -eq 'Destroy')
                if ($Command -eq 'Plan') { Write-Host 'Lifecycle plan saved in .local (no deletion/replacement).'; return }
                [void](Invoke-Tofu $Context @('apply', '-input=false', $plan))
                if ($Command -eq 'Destroy') { Write-Host 'Owned infra unregistered. Local state/downloads retained.'; return }
                $owner = Get-StateOwner $Context
                Invoke-GuestHandoff $Context $owner 'Apply'
                Write-Host 'Guest apply complete; kubeconfig: .local/kubeconfig'
                return
            }
            $record = Get-OwnedRecord $Context $owner
            if ($Command -eq 'Stop') {
                $running = ConvertFrom-WslList (Invoke-Wsl @('--list', '--running', '--quiet') -Unicode).Text
                if ($running -cnotcontains 'infra') { Write-Host 'Already stopped.'; return }
            }
            Assert-GuestMarker $record
            switch ($Command) {
                'Start' { Start-OwnedKeeper $Context $record; Write-Host 'Started owned infra; run Apply to resume stopped cluster containers, then Doctor.' }
                'Stop' { [void](Invoke-Wsl @('--terminate', 'infra')); Write-Host 'Stopped owned infra.' }
                'Smoke' { Invoke-GuestHandoff $Context $owner 'Smoke'; Write-Host 'Guest smoke completed.' }
            }
        }
    } finally { $env:INFRA_DESTROY_CONFIRM = $previous }
}
