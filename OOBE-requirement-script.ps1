# Requirement rule: return "InOOBE" only while the device is in OOBE/ESP.
$code = @"
using System;
using System.Runtime.InteropServices;
public static class Oobe {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int OOBEComplete(ref int isComplete);
}
"@
Add-Type -TypeDefinition $code -Language CSharp
$complete = 0
[Oobe]::OOBEComplete([ref]$complete) | Out-Null
if ($complete -eq 0) { Write-Output "InOOBE" } else { Write-Output "Provisioned" }
exit 0