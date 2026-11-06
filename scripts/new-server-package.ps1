[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [ValidateSet('win-x64')][string] $RuntimeIdentifier = 'win-x64',
    [switch] $KeepStaging
)
# Compatible entrypoint; emits three component archives and the bootstrap bundle.
& (Join-Path $PSScriptRoot 'new-platform-package.ps1') -OutputDirectory $OutputDirectory
