# Copper for Windows installer.
#
#   irm https://copper-browser.github.io/Copper/install.ps1 | iex
#
# Downloads the latest CopperSetup for this PC's processor (x64 or ARM64) from
# github.com/copper-browser/copper-windows, checks it against that release's
# SHA256SUMS, installs Copper for this user (%LOCALAPPDATA%\Programs\Copper, no
# admin; setup gets the WebView2 runtime too if this PC lacks it), and opens
# it. Re-running upgrades in place.
#
#   $env:COPPER_NO_LAUNCH = '1'   install without opening Copper afterwards
#
# Served by the Copper website (site/ in copper-browser/Copper). Windows
# PowerShell 5.1 and PowerShell 7 both run it; nothing else is needed.

& {
    $ErrorActionPreference = 'Stop'
    # The progress bar slows Invoke-WebRequest to a crawl on Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $feed = 'https://github.com/copper-browser/copper-windows/releases/latest/download'
    # A 32-bit or emulated shell reports its own CPU; the real one is in
    # PROCESSOR_ARCHITEW6432 then.
    $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($cpu) {
        'ARM64' { 'arm64' }
        'AMD64' { 'x64' }
        default { throw "Copper for Windows runs on x64 and ARM64 PCs; this one is $cpu." }
    }
    $name = "CopperSetup-$arch.exe"
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('copper-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $setup = Join-Path $dir $name
        Write-Host "==> downloading $feed/$name"
        Invoke-WebRequest -Uri "$feed/$name" -OutFile $setup -UseBasicParsing
        Invoke-WebRequest -Uri "$feed/SHA256SUMS" -OutFile (Join-Path $dir 'SHA256SUMS') -UseBasicParsing
        $line = Get-Content (Join-Path $dir 'SHA256SUMS') | Where-Object { ($_ -split '\s+')[1] -eq $name } | Select-Object -First 1
        if (-not $line) { throw "the latest release's SHA256SUMS does not list $name" }
        $want = ($line -split '\s+')[0]
        $have = (Get-FileHash -Path $setup -Algorithm SHA256).Hash.ToLower()
        if ($have -ne $want.ToLower()) {
            throw "checksum mismatch for $name (expected $want, got $have); a release may be mid-publish, retry in a minute"
        }
        Write-Host "==> sha256 verified ($have)"

        # Silent: no window and no questions. Setup never opens Copper itself
        # then, which is what lets -Wait return; this script opens it below.
        Write-Host "==> installing Copper for $env:USERNAME"
        $run = Start-Process -FilePath $setup -ArgumentList '--silent' -Wait -PassThru
        if ($run.ExitCode -ne 0) {
            throw "setup failed (exit $($run.ExitCode)); its log is $(Join-Path ([IO.Path]::GetTempPath()) 'CopperSetup.log')"
        }
        $exe = Join-Path $env:LOCALAPPDATA 'Programs\Copper\copper.exe'
        if (-not (Test-Path $exe)) { throw "setup finished but $exe is missing" }
        Write-Host "==> installed $exe"
        if ($env:COPPER_NO_LAUNCH -eq '1') {
            Write-Host '    not opening Copper (COPPER_NO_LAUNCH)'
        } else {
            Write-Host '==> opening Copper'
            Start-Process -FilePath $exe
        }
        Write-Host ''
        Write-Host 'Copper is installed. It is in the Start menu; to upgrade later, run this line again.'
    } finally {
        Remove-Item -Recurse -Force -Path $dir -ErrorAction SilentlyContinue
    }
}
