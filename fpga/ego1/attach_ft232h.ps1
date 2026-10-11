param(
    [string]$BusId
)

$ErrorActionPreference = "Stop"
$usbipd = Join-Path ${env:ProgramFiles} "usbipd-win\usbipd.exe"
if (-not (Test-Path -LiteralPath $usbipd)) {
    throw "usbipd-win is not installed. Install it with: winget install --id dorssel.usbipd-win --exact"
}

if ([string]::IsNullOrWhiteSpace($BusId)) {
    $lines = & $usbipd list
    $match = $lines | Where-Object { $_ -match '^\s*(\S+)\s+0403:6014\s+' } | Select-Object -First 1
    if ($null -eq $match) {
        Write-Host "No FT232H with VID:PID 0403:6014 was found. Plug in the external JTAG adapter, then run usbipd list."
        exit 2
    }
    $BusId = ([regex]::Match($match, '^\s*(\S+)\s+0403:6014\s+')).Groups[1].Value
}

$check = & $usbipd list | Where-Object { $_ -match "^\s*$([regex]::Escape($BusId))\s+0403:6014\s+" }
if ($null -eq $check) {
    throw "Bus ID '$BusId' is not an FT232H with VID:PID 0403:6014. Refusing to attach a different USB device."
}

Write-Host "Binding FT232H bus $BusId to usbipd..."
& $usbipd bind --busid $BusId
if ($LASTEXITCODE -ne 0) { throw "usbipd bind failed" }

Write-Host "Attaching FT232H bus $BusId to the default WSL distribution..."
& $usbipd attach --wsl --busid $BusId
if ($LASTEXITCODE -ne 0) { throw "usbipd attach failed" }

Write-Host "In WSL, verify with: lsusb | grep 0403:6014"
