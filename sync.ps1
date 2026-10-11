[CmdletBinding()]
param(
    [Alias("dry-run")]
    [switch]$DryRun,

    [string]$Message
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Publisher = Join-Path $RepoRoot "scripts\publish-zhihu-article.ps1"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & git -C $RepoRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return @($output)
}

function Get-ChangedMarkdown {
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $commands = @(
        @("-c", "core.quotepath=false", "-c", "core.autocrlf=false", "diff", "--name-only", "--diff-filter=ACMRD", "HEAD", "--", "*.md"),
        @("-c", "core.quotepath=false", "-c", "core.autocrlf=false", "diff", "--cached", "--name-only", "--diff-filter=ACMRD", "HEAD", "--", "*.md"),
        @("-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard", "--", "*.md")
    )

    foreach ($command in $commands) {
        foreach ($line in (Invoke-Git -Arguments $command)) {
            $path = ([string]$line).Trim()
            if ($path -and -not $path.StartsWith("warning:", [StringComparison]::OrdinalIgnoreCase)) {
                [void]$paths.Add(($path -replace "\\", "/"))
            }
        }
    }

    return @($paths | Sort-Object)
}

function Get-ZhihuArticleId {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $absolutePath = Join-Path $RepoRoot ($RelativePath -replace "/", "\\")
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -LiteralPath $absolutePath -Raw -Encoding UTF8
    $frontmatter = [regex]::Match($text, '\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*(?:\r?\n|\z)', 'Singleline')
    if (-not $frontmatter.Success) {
        return $null
    }

    $matches = [regex]::Matches(
        $frontmatter.Groups['yaml'].Value,
        '(?mi)^\s*(?:zhihu_article_id|zhihu_token|article_id)\s*:\s*["'']?(?<id>[0-9]+)["'']?\s*$'
    )
    if ($matches.Count -eq 0) {
        return $null
    }

    $ids = @($matches | ForEach-Object { $_.Groups['id'].Value } | Select-Object -Unique)
    if ($ids.Count -gt 1) {
        throw "$RelativePath contains conflicting Zhihu article IDs: $($ids -join ', ')"
    }
    return $ids[0]
}

function Get-LocalMarkdownAssets {
    param([Parameter(Mandatory = $true)][string[]]$MarkdownPaths)

    $assets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rootPrefix = [IO.Path]::GetFullPath($RepoRoot).TrimEnd("\\") + "\\"

    foreach ($relativePath in $MarkdownPaths) {
        $markdownPath = Join-Path $RepoRoot ($relativePath -replace "/", "\\")
        if (-not (Test-Path -LiteralPath $markdownPath -PathType Leaf)) {
            continue
        }

        $text = Get-Content -LiteralPath $markdownPath -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, '!\[[^\]]*\]\((?<target>[^\)]+)\)')) {
            $target = $match.Groups['target'].Value.Trim()
            if ($target.StartsWith("<") -and $target.EndsWith(">")) {
                $target = $target.Substring(1, $target.Length - 2)
            }
            $target = ($target -split '\s+["'']', 2)[0]
            if (-not $target -or $target.StartsWith("#") -or $target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
                continue
            }

            $decodedTarget = [Uri]::UnescapeDataString($target)
            $candidate = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $markdownPath) ($decodedTarget -replace "/", "\\")))
            if ($candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                [void]$assets.Add($candidate.Substring($rootPrefix.Length).Replace("\\", "/"))
            }
        }
    }

    return @($assets | Sort-Object)
}

try {
    [void](Invoke-Git -Arguments @("rev-parse", "--show-toplevel"))
    $changed = @(Get-ChangedMarkdown)
    $zhihuItems = @()
    $githubOnlyItems = @()

    foreach ($path in $changed) {
        $articleId = Get-ZhihuArticleId -RelativePath $path
        if ($articleId) {
            $zhihuItems += [pscustomobject]@{ Path = $path; ArticleId = $articleId }
        } else {
            $githubOnlyItems += $path
        }
    }

    Write-Host "Changed:"
    if ($changed.Count -eq 0) {
        Write-Host "(none)"
    } else {
        foreach ($item in $zhihuItems) {
            Write-Host "[Zhihu] $($item.Path) -> article $($item.ArticleId)"
        }
        foreach ($path in $githubOnlyItems) {
            Write-Host "[GitHub only] $path"
        }
    }

    if ($DryRun) {
        exit 0
    }

    if ($zhihuItems.Count -gt 0) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Publisher -Check
        if ($LASTEXITCODE -ne 0) {
            throw "Zhihu publisher preflight failed. No Git commit or push was performed."
        }

        Write-Host ""
        Write-Host "Zhihu:"
        $failed = @()
        foreach ($item in $zhihuItems) {
            $absolutePath = Join-Path $RepoRoot ($item.Path -replace "/", "\\")
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Publisher -File $absolutePath -ArticleId $item.ArticleId
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] $($item.Path)"
            } else {
                $failed += $item
                Write-Host "[FAILED] $($item.Path) -> article $($item.ArticleId)" -ForegroundColor Red
                break
            }
        }

        if ($failed.Count -gt 0) {
            Write-Host ""
            Write-Host "Failed articles:"
            foreach ($item in $failed) {
                Write-Host "- $($item.Path) -> article $($item.ArticleId)"
            }
            throw "Zhihu synchronization failed. Local changes were preserved; Git commit and push were skipped."
        }
    }

    $pendingBefore = @(Invoke-Git -Arguments @("rev-list", "@{upstream}..HEAD") -AllowFailure)
    $hasPendingCommits = $LASTEXITCODE -eq 0 -and $pendingBefore.Count -gt 0 -and ($pendingBefore -join '').Trim()

    if ($changed.Count -gt 0) {
        $stagePaths = @($changed) + @(Get-LocalMarkdownAssets -MarkdownPaths $changed)
        foreach ($path in ($stagePaths | Select-Object -Unique)) {
            [void](Invoke-Git -Arguments @("add", "--", $path))
        }
        $commitMessage = if ($Message) { $Message } else { "Sync articles $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
        [void](Invoke-Git -Arguments @("commit", "-m", $commitMessage))
        $hasPendingCommits = $true
        Write-Host ""
        Write-Host "Git:"
        Write-Host "[OK] committed"
    } elseif (-not $hasPendingCommits) {
        Write-Host ""
        Write-Host "Git:"
        Write-Host "(nothing to commit or push)"
        exit 0
    } else {
        Write-Host ""
        Write-Host "Git:"
        Write-Host "(retrying pending push)"
    }

    [void](Invoke-Git -Arguments @("push", "origin", "HEAD:main"))
    Write-Host "[OK] pushed"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
