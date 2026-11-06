$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pilot-protocol-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $temp 'scripts') -Force)
try {
    Copy-Item (Join-Path $repo 'scripts\ps-compat.ps1') (Join-Path $temp 'scripts')
    $source=[IO.File]::ReadAllText((Join-Path $repo 'scripts\pilot-env.ps1'))
    $stub = '$script:DockerCommand = $true; function docker { $global:LASTEXITCODE=0; if($args[0] -eq "pull") { "release: Pulling from synthetic-test"; "Status: Downloaded newer image"; return }; if($args[0] -eq "info") { "test-version"; return }; if($args[0] -eq "image") { "synthetic/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; return }; throw "Unexpected synthetic Docker command" }'
    $source=$source.Replace('$script:DockerCommand = Enable-PilotDockerCompatibility',$stub)
    [IO.File]::WriteAllText((Join-Path $temp 'scripts\pilot-env.ps1'),$source,(New-Object Text.UTF8Encoding($true)))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $temp 'scripts\pilot-env.ps1')+'" ResolveRelease -Json -Machine'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.EnvironmentVariables['PILOT_DATA_ROOT']=$temp
    $info.EnvironmentVariables['PILOT_ENGINE_ROOT']=$temp
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout=$outTask.Result;$stderr=$errTask.Result
    $envelope=$stdout | ConvertFrom-Json -ErrorAction Stop
    if($process.ExitCode -ne 0 -or -not $envelope.success -or $envelope.protocolVersion -ne 1){throw 'Machine action failed'}
    if($stderr -notmatch 'release: Pulling from synthetic-test'){throw 'Docker pull diagnostic lost'}
    if(-not $envelope.data.images.server){throw 'Structured release missing'}
    Write-Host 'Machine output: OK (real PS5 child process, Docker pull diagnostics isolated, strict JSON stdout).'
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
