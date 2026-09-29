<#
.SYNOPSIS
Serves the review page from this clone on localhost.

.DESCRIPTION
Browsers do not load JavaScript modules from file:// URLs, so the page needs a
small web server. This script serves site/ on the loopback interface only and
has no dependencies. Press Ctrl+C to stop it.

.EXAMPLE
./scripts/Start-ReviewPage.ps1 -Open
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8767,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$siteRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'site'))
$rootPrefix = $siteRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$contentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg' = 'image/svg+xml'
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Information "Review page is running at $prefix (Ctrl+C to stop)." -InformationAction Continue
if ($Open) {
    Start-Process $prefix
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response
        try {
            $relative = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath).TrimStart('/')
            if ($relative -eq '') {
                $relative = 'index.html'
            }
            $path = [System.IO.Path]::GetFullPath((Join-Path $siteRoot $relative))
            $type = $contentTypes[[System.IO.Path]::GetExtension($path).ToLowerInvariant()]
            if ($context.Request.HttpMethod -ne 'GET' -or -not $type -or
                -not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $response.StatusCode = 404
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $response.ContentType = $type
            $response.Headers['Cache-Control'] = 'no-store'
            $response.Headers['X-Content-Type-Options'] = 'nosniff'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $response.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
