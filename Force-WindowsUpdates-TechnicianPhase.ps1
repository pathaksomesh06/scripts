<#
.SYNOPSIS
    Forces Windows quality/security updates (incl. the latest cumulative, LCU) during
    the Autopilot pre-provisioning (technician) phase, before user enrollment.

    Feature-version agnostic: it advances the device to the newest BUILD of whatever
    feature version it is already on (24H2 -> latest 26100.x, 25H2 -> latest 26200.x)
    and never performs a feature/version change. The 24H2->25H2 enablement package is
    excluded both by category (Upgrades) and by title (Feature update / Enablement
    Package), so the running version is preserved.

.NOTES
    - Deploy as a Win32 app in the ESP (runs as SYSTEM by default).
    - Pre-stage PSWindowsUpdate: run  Save-Module PSWindowsUpdate -Path .\PSWindowsUpdate
      and ship that 'PSWindowsUpdate' folder next to this script in the .intunewin.
    - Intune Win32 return codes: 0 = success, 3010 = soft reboot, 1 = failure.
    - Detection rule: file exists  C:\ProgramData\IntuneWU\ForceUpdates.success.tag
    - Temporarily clears the WUfB quality deferral during the run to pull the newest
      LCU, then restores it. The Update Ring is never changed; prod deferral is intact.
#>

#region Config
# Log goes to the IME Logs folder so it's captured by Intune "Collect diagnostics"
# and sits alongside IntuneManagementExtension.log for troubleshooting.
$LogDir  = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDir 'ForceUpdates.log'
# Detection tag stays in its own folder (the Intune detection rule points here).
$TagDir  = "$env:ProgramData\IntuneWU"
$TagFile = Join-Path $TagDir 'ForceUpdates.success.tag'

# Optional: exact builds ('Build.UBR') to hard-skip as Insider, for devices flashed
# from Insider ISOs that do NOT set the flighting registry. Use EXACT strings only -
# never a wildcard on a retail build family (26100/26200) or you will skip production.
# Example: $InsiderBuildBlocklist = @('26100.1','26200.1')
$InsiderBuildBlocklist = @()
#endregion

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path $LogFile -Append | Out-Null

$RebootNeeded = $false

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- Step 0: Skip on Windows Insider / flighting devices ---
    # Insider devices receive builds through their flighting channel, so forcing updates
    # here is inappropriate. Primary signal = WindowsSelfHost flighting registry
    # (authoritative). Secondary = optional exact-build block list for devices flashed
    # from Insider ISOs without flighting keys. Build numbers are NOT reliable on their
    # own - Release Preview Insiders share the retail family (26100.x / 26200.x) - so the
    # block list must use EXACT 'Build.UBR' strings. On skip we still write the tag and
    # exit 0, so detection passes and ESP is NOT failed.
    $SkipReason = $null

    $SelfHost = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability'
    if (Test-Path $SelfHost) {
        $sh = Get-ItemProperty -Path $SelfHost -ErrorAction SilentlyContinue
        if ($sh.BranchName -or $sh.Ring -or $sh.ContentType -or ($sh.EnablePreviewBuilds -eq 1)) {
            $SkipReason = "Insider/flighting device (BranchName='$($sh.BranchName)', Ring='$($sh.Ring)', ContentType='$($sh.ContentType)')"
        }
    }

    if (-not $SkipReason -and $InsiderBuildBlocklist.Count -gt 0) {
        $cvi      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $BuildUBR = "$($cvi.CurrentBuildNumber).$($cvi.UBR)"
        if ($InsiderBuildBlocklist -contains $BuildUBR) {
            $SkipReason = "build $BuildUBR is in the Insider block list"
        }
    }

    if ($SkipReason) {
        Write-Output "Skipping update run: $SkipReason."
        if (-not (Test-Path $TagDir)) { New-Item -Path $TagDir -ItemType Directory -Force | Out-Null }
        New-Item -Path $TagFile -ItemType File -Force | Out-Null   # tag written so detection passes
        Write-Output "Skipped on Insider build - exit 0 (ESP not failed)."
        Stop-Transcript | Out-Null
        exit 0
    }

    # --- Step 1: Bootstrap PSWindowsUpdate (offline-first, PSGallery fallback) ---
    # IMPORTANT: the module must exist in PSModulePath (not just be imported from the
    # package folder), or installs fail with "PSWindowsUpdate module missing on
    # destination machine". So copy the bundled module into the system Modules dir.
    $Local      = Join-Path $PSScriptRoot 'PSWindowsUpdate'
    $SystemMods = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'
    if (Test-Path $Local) {
        if (-not (Test-Path $SystemMods)) {
            Copy-Item -Path $Local -Destination $SystemMods -Recurse -Force
            Write-Output "Bundled PSWindowsUpdate copied to system Modules folder."
        }
        Import-Module PSWindowsUpdate -Force
    }
    else {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module PSWindowsUpdate -Force -Scope AllUsers
        Import-Module PSWindowsUpdate -Force
    }

    # --- Step 2: Quality/security updates (Windows only, no feature upgrades) ---
    # Temporarily lift the WUfB quality deferral so the NEWEST cumulative (LCU) is
    # offered during pre-provisioning, then restore it. Production policy is untouched
    # (the ring is never modified, and Intune reasserts the value on next MDM sync).
    $PolicyPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $OrigDefer  = (Get-ItemProperty $PolicyPath -Name DeferQualityUpdatesPeriodInDays -ErrorAction SilentlyContinue).DeferQualityUpdatesPeriodInDays

    try {
        if (Test-Path $PolicyPath) {
            Set-ItemProperty $PolicyPath -Name DeferQualityUpdatesPeriodInDays -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Write-Output "Quality deferral temporarily set to 0 (was: $OrigDefer)."
            Start-Sleep -Seconds 5   # let WU pick up the change before scanning
        }

        Write-Output "=== Quality / security updates ==="

        # Detect the running feature version so the run is explicitly version-aware.
        # The device STAYS on this version; only its build (LCU) is advanced.
        # 24H2 -> latest 26100.x, 25H2 -> latest 26200.x, etc. - WU offers the LCU
        # that matches the version already installed, so this is version-agnostic.
        $CV             = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $FeatureVersion = $CV.DisplayVersion                       # e.g. 24H2 / 25H2 / 26H2
        $CurrentBuild   = "$($CV.CurrentBuildNumber).$($CV.UBR)"   # e.g. 26100.1742
        Write-Output ("Current feature version: {0} (build {1}). Installing latest quality updates for this version - NO feature/version change." -f $FeatureVersion, $CurrentBuild)

        # Scan once and log what will be installed (this flushes immediately).
        # Exclusions:
        #   Upgrades  - feature/version updates (the 24H2->25H2 jump lives here)
        #   Drivers   - driver/firmware (cause of CBS contention and UEFI PPI prompts)
        #   -NotTitle - belt-and-suspenders: the enablement package (eKB) is titled
        #               "Feature update to..."; this blocks the version flip even if
        #               it were ever mis-categorised outside the Upgrades bucket.
        $Pending = Get-WindowsUpdate -NotCategory 'Upgrades','Drivers' -NotTitle 'Feature update|Enablement Package' -ErrorAction SilentlyContinue
        if (-not $Pending) {
            Write-Output "No quality updates pending."
        }
        else {
            Write-Output ("Found {0} update(s):" -f @($Pending).Count)
            foreach ($u in $Pending) {
                Write-Output ("  - {0}  {1}  ({2})" -f $u.KB, $u.Title, $u.Size)
            }

            # Install (direct call - NEVER pipe update objects into Install-WindowsUpdate,
            # it binds them to -ComputerName and fails with "module missing on destination
            # machine"). Verbose stream (4>&1) is relayed line-by-line for live logging.
            # Result objects are collected for the success check below.
            $InstallResults = @()
            Install-WindowsUpdate -NotCategory 'Upgrades','Drivers' -NotTitle 'Feature update|Enablement Package' -AcceptAll -IgnoreReboot -Verbose 4>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.VerboseRecord]) {
                        $line = $_.Message
                    }
                    else {
                        $InstallResults += $_
                        $line = ($_ | Out-String).Trim()
                    }
                    if ($line) { Write-Output ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line) }
                }

            # --- Result check (install phase only, unique per title) ---
            # PSWindowsUpdate emits a result object per phase (Accepted/Downloaded/
            # Installed), so filter to the install phase and de-duplicate by Title.
            $InstalledOK = @($InstallResults |
                Where-Object { $_.Result -eq 'Installed' } |
                Sort-Object Title -Unique)
            $FailedSet   = @($InstallResults |
                Where-Object { $_.Result -eq 'Failed' } |
                Sort-Object Title -Unique)

            Write-Output ("Result check: {0} installed, {1} failed, of {2} pending." -f $InstalledOK.Count, $FailedSet.Count, @($Pending).Count)
            if ($FailedSet.Count -gt 0) {
                foreach ($f in $FailedSet) { Write-Output ("  FAILED: {0} {1}" -f $f.KB, $f.Title) }
            }

            # Gate 1: nothing installed at all -> hard fail (no tag).
            if ($InstalledOK.Count -eq 0) {
                throw "All pending updates failed to install - failing so the detection tag is NOT written."
            }

            # Gate 2: LCU-aware. If a cumulative/security OS update was pending,
            # it MUST be among the installed set - otherwise fail (no tag), so a
            # device can never report success while still on the old build.
            $LcuPattern = 'Cumulative Update for Windows|Security Update \(KB'
            $LcuPending = @($Pending | Where-Object { $_.Title -match $LcuPattern })
            if ($LcuPending.Count -gt 0) {
                $LcuInstalled = @($InstalledOK | Where-Object { $_.Title -match $LcuPattern })
                if ($LcuInstalled.Count -eq 0) {
                    throw ("Cumulative update '{0}' failed to install - failing so the detection tag is NOT written." -f $LcuPending[0].Title)
                }
                Write-Output ("LCU check passed: {0}" -f $LcuInstalled[0].Title)
                # An LCU always needs a restart to commit - don't trust the WU flag.
                $RebootNeeded = $true
            }
        }

        # Reboot detection: PSWindowsUpdate's flag is unreliable right after install,
        # so also check the servicing/WU pending-reboot registry markers.
        if (Get-WURebootStatus -Silent) { $RebootNeeded = $true }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $RebootNeeded = $true }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $RebootNeeded = $true }
    }
    finally {
        # Always restore the original deferral, even if the install above errored
        if ($null -ne $OrigDefer) {
            Set-ItemProperty $PolicyPath -Name DeferQualityUpdatesPeriodInDays -Value $OrigDefer -Type DWord -ErrorAction SilentlyContinue
            Write-Output "Quality deferral restored to $OrigDefer."
        }
    }

    # --- Step 3: Success marker + exit codes ---
    if (-not (Test-Path $TagDir)) { New-Item -Path $TagDir -ItemType Directory -Force | Out-Null }
    New-Item -Path $TagFile -ItemType File -Force | Out-Null

    if ($RebootNeeded) {
        Write-Output "Updates installed - reboot required (exit 3010)."
        Stop-Transcript | Out-Null
        exit 3010   # soft reboot -> ESP handles restart and resumes
    }
    else {
        Write-Output "Updates installed - no reboot required (exit 0)."
        Stop-Transcript | Out-Null
        exit 0
    }
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1   # failure -> ESP marks the app failed
}
