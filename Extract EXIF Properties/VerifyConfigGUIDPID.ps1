$imagePath = "C:\Workspace\LOCAL SANDBOX\Photo Metadata Extract\IMG_2278.jpeg"

$objShell = New-Object -ComObject Shell.Application
$objFolder = $objShell.Namespace([System.IO.Path]::GetDirectoryName($imagePath))
$objFile = $objFolder.ParseName([System.IO.Path]::GetFileName($imagePath))


# Load the property system API
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class PropSys {
    [DllImport("propsys.dll", CharSet = CharSet.Unicode)]
    public static extern int PSGetPropertyKeyFromName(string pszName, out PROPERTYKEY ppropkey);

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }
}
"@

# Check the actual GUID/PID for Camera Manufacturer
$propKey = New-Object PropSys+PROPERTYKEY
$result = [PropSys]::PSGetProperty
KeyFromName("System.Photo.CameraManufacturer", [ref]$propKey)

if ($result -eq 0) {
    Write-Host "System.Photo.CameraManufacturer:" -ForegroundColor Yellow
    Write-Host "  GUID: $($propKey.fmtid)"
    Write-Host "  PID: $($propKey.pid)"
} else {
    Write-Host "Failed to get property key" -ForegroundColor Red
}

# Check Camera Model
$propKey2 = New-Object PropSys+PROPERTYKEY
$result2 = [PropSys]::PSGetPropertyKeyFromName("System.Photo.CameraModel", [ref]$propKey2)

if ($result2 -eq 0) {
    Write-Host "`nSystem.Photo.CameraModel:" -ForegroundColor Yellow
    Write-Host "  GUID: $($propKey2.fmtid)"
    Write-Host "  PID: $($propKey2.pid)"
}