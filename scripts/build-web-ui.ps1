param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PilotEnv.Web'
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
# These dependency-ordered modules have no dynamic imports. Ship one native module
# so the new UI also works with the previous API's static asset allow-list.
$modules=@('labels.js','api-client.js','operation-state.js','cards.js','journal.js','app.js')
$parts=@()
foreach($file in $modules){
 $text=[IO.File]::ReadAllText((Join-Path $source $file))
 $text=[regex]::Replace($text,'(?ms)^import\s+.*?;\r?\n','')
 $text=[regex]::Replace($text,'(?m)^export ','')
 $parts+=('// '+$file+"`n"+$text)
 if($file -eq 'labels.js'){$parts+='const e=escapeHtml;'}
}
$text=($parts -join "`n")
$text="// Local aliases shared by presentation modules.`n"+$text
# escapeHtml is the only imported alias in the presentation modules.
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'app.js'),$text,(New-Object Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $source 'index.html'),(Join-Path $source 'styles.css') -Destination $OutputDirectory -Force
Copy-Item -LiteralPath (Join-Path $source 'help.pdf') -Destination $OutputDirectory -Force
