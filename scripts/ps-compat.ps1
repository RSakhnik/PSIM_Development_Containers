Set-StrictMode -Version Latest

function Test-PilotWindowsHost {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-PilotWindowsPowerShellPath {
    $path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell was not found: $path"
    }
    return $path
}

function New-PilotRandomBytes {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 4096)][int] $Count)

    $bytes = New-Object byte[] $Count
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) }
    finally { $generator.Dispose() }
    return ,$bytes
}

function Write-PilotUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string] $LiteralPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($LiteralPath), $Text, $encoding)
}

function Invoke-PilotDockerNative {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $script:PilotDockerExecutable @args
    }
    finally {
        $nativeExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        Set-Variable -Name LASTEXITCODE -Value $nativeExitCode -Scope 1
    }
}

function Enable-PilotDockerCompatibility {
    $command = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $command) { return $null }

    $script:PilotDockerExecutable = $command.Source
    Set-Alias -Name docker -Value Invoke-PilotDockerNative -Scope Script
    return $command
}

# Use structured SCM arguments: Windows PowerShell native quoting must not alter ImagePath.
function Set-PilotServiceCommand {
    param([string] $Name, [string] $BinaryPath)
    $service = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''"))
    if (-not $service) { throw "Service '$Name' does not exist." }
    $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{PathName=$BinaryPath;StartMode='Automatic'}
    if ($result.ReturnValue -ne 0) { throw "Service command update failed: SCM code $($result.ReturnValue)." }
    $actual = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''"))
    if ($actual.PathName -cne $BinaryPath) { throw 'SCM executable path read-back differs from the requested command.' }
}

function New-PilotConfigurationImportBody {
    param([Parameter(Mandatory=$true)][string] $LiteralPath)
    # .pilotcfx is UTF-8 XML; do not use Windows PowerShell ANSI defaults.
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    $text = [IO.File]::ReadAllText($LiteralPath,$encoding)
    $json = @{databaseName='pilot-bim_ru';data=$text} | ConvertTo-Json -Compress
    return ,$encoding.GetBytes($json)
}
