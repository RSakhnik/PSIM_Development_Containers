Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ps-compat.ps1')

function Write-PlatformJson($Path, $Value) {
    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp')
    Write-PilotUtf8NoBom -LiteralPath $temporary -Text ($Value | ConvertTo-Json -Depth 40)
    try {
        for($attempt=0;;$attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
                break
            } catch [IO.IOException] { if($attempt -ge 19){throw};Start-Sleep -Milliseconds 50 }
        }
    } finally { if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force} }
}

function Get-PlatformHash([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Assert-PlatformBuildHash([string] $BuildHash) {
    if ($BuildHash -notmatch '^[a-f0-9]{64}$') { throw "Invalid component build hash: $BuildHash" }
}

function Get-PlatformBuildPath([string] $Root, [string] $Component, [string] $BuildHash) {
    if($Component -notin @('web-ui','control-api','environment-engine')){throw 'Unknown platform component.'}
    Assert-PlatformBuildHash $BuildHash
    return Join-Path $Root ".pilot-runtime\builds\$Component\$BuildHash"
}

function Resolve-PlatformChild([string] $Root, [string] $Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match ':') { throw "Invalid package path: $Relative" }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $target.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Package path escapes root: $Relative" }
    return $target
}

function Test-PlatformComponent([string] $Directory) {
    $manifestPath = Join-Path $Directory 'component-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2 -or $manifest.component -notin @('web-ui','control-api','environment-engine')) { throw 'Unknown component manifest. Rebuild with the current packager.' }
    $listed = @{}
    foreach ($file in $manifest.files) {
        $path = Resolve-PlatformChild $Directory ([string]$file.path)
        if ($listed.ContainsKey($path)) { throw "Duplicate package path: $($file.path)" }
        $listed[$path] = $true
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-PlatformHash $path) -ne $file.sha256) { throw "Package hash mismatch: $($file.path)" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse) {
        if ($file.FullName -ne $manifestPath -and -not $listed.ContainsKey($file.FullName)) { throw "Unlisted package file: $($file.Name)" }
    }
    return $manifest
}

function Assert-PlatformCompatibility($Manifests) {
    foreach ($kind in @('web-ui','control-api','environment-engine')) {
        if (-not $Manifests.ContainsKey($kind)) { throw "Missing compatible component: $kind. Install a full bundle." }
    }
    $api = [int]$Manifests['control-api'].provides.apiContract
    $protocol = [int]$Manifests['environment-engine'].provides.engineProtocol
    foreach ($m in $Manifests.Values) {
        if ($api -lt $m.requires.apiContractMin -or $api -gt $m.requires.apiContractMax -or
            $protocol -lt $m.requires.engineProtocolMin -or $protocol -gt $m.requires.engineProtocolMax -or
            [int]$Manifests['environment-engine'].provides.instanceSchema -lt $m.requires.instanceSchemaMin -or [int]$Manifests['environment-engine'].provides.instanceSchema -gt $m.requires.instanceSchemaMax) {
            throw "Incompatible component '$($m.component)'. Update the API/UI/engine as a compatible bundle."
        }
    }
}

function Expand-PlatformArchive([string] $Archive, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try { foreach ($entry in $zip.Entries) { if ($entry.FullName.TrimEnd('/','\')) { [void](Resolve-PlatformChild $Destination $entry.FullName) } } }
    finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
}
