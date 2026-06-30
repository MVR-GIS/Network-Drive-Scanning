$imagePath = "C:\Workspace\LOCAL SANDBOX\Photo Metadata Extract\IMG_2278.jpeg"

$objShell = New-Object -ComObject Shell.Application
$objFolder = $objShell.Namespace([System.IO.Path]::GetDirectoryName($imagePath))
$objFile = $objFolder.ParseName([System.IO.Path]::GetFileName($imagePath))

for ($i = 0; $i -lt 500; $i++) {
    $propName = $objFolder.GetDetailsOf($objFolder.Items, $i)
    $propValue = $objFolder.GetDetailsOf($objFile, $i)
    
    if ($propName -like "*GPS*" -or $propName -like "*Latitude*" -or $propName -like "*Longitude*" -or $propName -like "*Coord*") {
        Write-Host "$i - $propName : $propValue" -ForegroundColor Green
    }
    elseif ($propValue) {
        Write-Host "$i - $propName : $propValue"
    }
}