[CmdletBinding()]
param(
    [switch]$Check,
    [string]$File,
    [string]$ArticleId
)

$ErrorActionPreference = "Stop"
$Cli = "C:\Users\32599\AppData\Local\ZhihuCLI\current\zhihu-cli.exe"

if (-not (Test-Path -LiteralPath $Cli -PathType Leaf)) {
    Write-Error "Zhihu CLI is not installed at the expected path: $Cli"
    exit 1
}

try {
    $capabilities = (& $Cli capabilities | ConvertFrom-Json)
} catch {
    Write-Error "Unable to read Zhihu CLI capabilities: $($_.Exception.Message)"
    exit 1
}

$writeCommands = @(
    $capabilities.commands | Where-Object {
        $_.side_effect -eq $true -and
        $_.name -match '(?i)(article|content)' -and
        $_.name -match '(?i)(update|edit|publish)'
    }
)

if ($writeCommands.Count -eq 0) {
    Write-Error @"
The installed Zhihu Skill/CLI does not expose an article update command.
Detected CLI version: $($capabilities.version)
No article was updated. Add an official article-update capability to this adapter when Zhihu provides one; do not replace it with an undocumented private API.
"@
    exit 2
}

if ($Check) {
    Write-Error "A new Zhihu write capability was detected, but this adapter has not been mapped to its documented CLI arguments yet. Review '$($writeCommands.name -join ', ')' before publishing."
    exit 3
}

if (-not $File -or -not $ArticleId) {
    Write-Error "-File and -ArticleId are required."
    exit 1
}

Write-Error "Zhihu update adapter is not configured for the detected CLI command."
exit 3
