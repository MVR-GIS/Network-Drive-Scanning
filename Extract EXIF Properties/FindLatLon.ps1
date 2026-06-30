$imagePath = "C:\Workspace\LOCAL SANDBOX\Photo Metadata Extract\IMG_2278.jpeg"

[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null
$image = [System.Drawing.Image]::FromFile($imagePath)

function Get-GPSDecimal {
    param($propItem, $refPropItem)
    
    $bytes = $propItem.Value
    
    $deg = [BitConverter]::ToUInt32($bytes, 0) / [BitConverter]::ToUInt32($bytes, 4)
    $min = [BitConverter]::ToUInt32($bytes, 8) / [BitConverter]::ToUInt32($bytes, 12)
    $sec = [BitConverter]::ToUInt32($bytes, 16) / [BitConverter]::ToUInt32($bytes, 20)
    
    $decimal = $deg + ($min / 60) + ($sec / 3600)
    
    if ($refPropItem) {
        $ref = [System.Text.Encoding]::ASCII.GetString($refPropItem.Value)
        if ($ref -eq "S" -or $ref -eq "W") {
            $decimal = -$decimal
        }
    }
    
    return $decimal
}

$latProp = $image.PropertyItems | Where-Object { $_.Id -eq 0x0002 }
$latRefProp = $image.PropertyItems | Where-Object { $_.Id -eq 0x0001 }
$lonProp = $image.PropertyItems | Where-Object { $_.Id -eq 0x0004 }
$lonRefProp = $image.PropertyItems | Where-Object { $_.Id -eq 0x0003 }

if ($latProp -and $lonProp) {
    $latitude = Get-GPSDecimal $latProp $latRefProp
    $longitude = Get-GPSDecimal $lonProp $lonRefProp
    
    Write-Host "Latitude: $latitude"
    Write-Host "Longitude: $longitude"
} else {
    Write-Host "GPS data not found"
}

$image.Dispose()