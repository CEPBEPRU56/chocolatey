Write-Host "Windows10-Autounattend"

$runOnceRegistryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"

# Set Windows Activation Key from UEFI
$licensingService = Get-WmiObject -Query "SELECT * FROM SoftwareLicensingService"
if ($key = $licensingService.OA3xOriginalProductKey) {
	Write-Host "Product Key: $licensingService.OA3xOriginalProductKey"
	$licensingService.InstallProductKey($key) | Out-Null
} else {
	Write-Host "Windows Activation Key not found."
}


# Change Power Plan (2 hour)
powercfg -change standby-timeout-ac 120
powercfg -change disk-timeout-ac 120
powercfg -change monitor-timeout-ac 120
powercfg -change hibernate-timeout-ac 120

# Install Nuget PackageProvider
#if (-Not (Get-PackageProvider -Name NuGet)) {
    Write-Host "Install Nuget PackageProvider"
    Install-PackageProvider -Name NuGet -Confirm:$false -Force | Out-Null
#}

# Install PendingReboot Module
if (-Not (Get-Module -ListAvailable -Name PendingReboot)) {
    Write-Host "Install PendingReboot Module"
    Install-Module PendingReboot -Confirm:$false -Force | Out-Null
}

# Import PendingReboot Module
Import-Module PendingReboot

# Install WindowsUpdate Module
if (-Not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "Install WindowsUpdate Module"
    Install-Module PSWindowsUpdate -Confirm:$false -Force | Out-Null
}

# Check is busy
while ((Get-WUInstallerStatus).IsBusy) {
    Write-Host "Windows Update installer is busy, wait..."
    Start-Sleep -s 10
}

# Install available Windows Updates (less 1GB)
Write-Host "Start installation system updates..."
Write-Host "This job will be automatically canceled if it takes longer than 15 minutes to complete"
Set-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!" -Value "cmd /c powershell -ExecutionPolicy ByPass -File $PSCommandPath" | Out-Null

$updateJobTimeoutSeconds = 900

$code = {
    if ((Get-WindowsUpdate -MaxSize 1073741824 -Verbose).Count -gt 0) {
        try {
            $status = Get-WindowsUpdate -MaxSize 1073741824 -Install -AcceptAll -Confirm:$false
            if (($status | Where Result -eq "Installed").Length -gt 0)
            {
                Restart-Computer -Force
                return
            }
            
            if ((Test-PendingReboot).IsRebootPending) {
                Restart-Computer -Force
                return
            }
        } catch {
            Write-Host "Error:`r`n $_.Exception.Message"
            Restart-Computer -Force
        }
    }
}

$updateJob = Start-Job -ScriptBlock $code
if (Wait-Job $updateJob -Timeout $updateJobTimeoutSeconds) { 
    Receive-Job $updateJob
} else {
    Write-Host "Timeout exceeded"
    Receive-Job $updateJob
    Start-Sleep -s 10
}
Remove-Job -force $updateJob

# Install Hardware Manufacturer Updates
Write-Host "Check manufacturer"

$manufacturer = (Get-ComputerInfo | Select -expand CsManufacturer)

if ($manufacturer -eq "ASUS") {
    Write-Host "ASUS detected"
    Write-Host "Start installation manufacturer updates..."

    # Install PendingReboot Module
    if (-Not (Get-Module -ListAvailable -Name LSUClient)) {
        Write-Host "Install LSUClient Module"
        Install-Module LSUClient -Confirm:$false -Force
    }

    $updates = Get-LSUpdate
    $updates | Save-LSUpdate -ShowProgress
    $updates | Install-LSUpdate -Verbose
}

# Install Chocolatey
if (-Not (Test-Path "$($env:ProgramData)\chocolatey\choco.exe")) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

# Required Chocolatey packages
$requiredPackages = @([pscustomobject]@{Name="notepadplusplus";Trust=$False},
                      [pscustomobject]@{Name="7zip.install";Trust=$False},
                      [pscustomobject]@{Name="adobereader";Trust=$False},
                      [pscustomobject]@{Name="googlechrome";Trust=$True})
					  [pscustomobject]@{Name="vcredist-all";Trust=$True})
					  [pscustomobject]@{Name="python3";Trust=$True})
					  [pscustomobject]@{Name="paint.net";Trust=$True})
					  [pscustomobject]@{Name="winrar";Trust=$True})
					  [pscustomobject]@{Name="k-litecodecpackfull";Trust=$True})
					  [pscustomobject]@{Name="nvidia-display-driver";Trust=$True})
					  [pscustomobject]@{Name="vlc.install";Trust=$True})
					  [pscustomobject]@{Name="qbittorrent";Trust=$True})
					  [pscustomobject]@{Name="totalcommander";Trust=$True})
					  [pscustomobject]@{Name="telegram.install";Trust=$True})
					  [pscustomobject]@{Name="obs-studio.install";Trust=$True})
					  [pscustomobject]@{Name="potplayer";Trust=$True})
					  [pscustomobject]@{Name="fsviewer";Trust=$True})
					  [pscustomobject]@{Name="fscapture";Trust=$True})
					  [pscustomobject]@{Name="recuva";Trust=$True})
					  [pscustomobject]@{Name="avidemux";Trust=$True})

# Load installed packages
$installedPackages = New-Object Collections.Generic.List[String]
$installedPackagesPath = Join-Path -Path $PSScriptRoot -ChildPath "installedPackages.txt"
if (Test-Path $installedPackagesPath -PathType Leaf) {
    $installedPackages.AddRange([string[]](Get-Content $installedPackagesPath))
}

# Calculate missing packages
$missingPackages = $requiredPackages | Where-Object { $installedPackages -NotContains $_.Name }

foreach ($package in $missingPackages) {
    if ((Test-PendingReboot).IsRebootPending) {
        Set-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!" -Value "cmd /c powershell -ExecutionPolicy ByPass -File $PSCommandPath"
        Restart-Computer -Force
        return
    }

    if ($package.Trust) {
        Write-Host "Install Package without checksum check"
        choco install $package.Name -y --ignore-checksums
    } else {
        Write-Host "Install Package with checksum check"
        choco install $package.Name -y
    }

    # Add package to installed package list
    $installedPackages.Add($package.Name)

    # Save update to file
    $installedPackages | Out-File $installedPackagesPath
}

Remove-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!"

$pathCustomizeScript = "C:\Temp\Unattended\customize.ps1"
if (Test-Path $pathCustomizeScript -PathType Leaf) {
    Write-Host "Found customize scirpt"
    & $pathCustomizeScript
}

Write-Host "Installation done"
Start-Sleep -s 60
