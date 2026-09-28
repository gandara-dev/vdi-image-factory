<#
.SYNOPSIS
Serves the Image Builder page from this clone on localhost.

.DESCRIPTION
Browsers do not load JavaScript modules from file:// URLs, so the page needs a
small web server. This script serves site/ and the reference JSON files in
config/ on the loopback interface only. It has no dependencies and works on
Windows PowerShell 5.1 and PowerShell 7. Press Ctrl+C to stop it.

.EXAMPLE
./scripts/Start-ImageBuilder.ps1 -Open
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8765,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$siteRoot = Join-Path $repositoryRoot 'site'
$configFiles = @(
    'application-catalog.json'
    'build.example.json'
    'windows-locales.json'
    'windows-time-zones.json'
)
$contentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg' = 'image/svg+xml'
    '.png' = 'image/png'
}

function Resolve-RequestPath {
    param([string]$UrlPath)

    $relative = [Uri]::UnescapeDataString($UrlPath).TrimStart('/')
    if ($relative -eq '') {
        $relative = 'index.html'
    }
    if ($relative -like 'config/*') {
        $name = $relative.Substring('config/'.Length)
        if ($configFiles -contains $name) {
            return Join-Path (Join-Path $repositoryRoot 'config') $name
        }
        return $null
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $siteRoot $relative))
    $root = [System.IO.Path]::GetFullPath($siteRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $candidate
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Information "Image Builder is running at $prefix (Ctrl+C to stop)." -InformationAction Continue
if ($Open) {
    Start-Process $prefix
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response
        try {
            $path = Resolve-RequestPath $context.Request.Url.AbsolutePath
            if ($context.Request.HttpMethod -ne 'GET' -or -not $path -or
                -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $response.StatusCode = 404
                continue
            }
            $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
            $type = $contentTypes[$extension]
            if (-not $type) {
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
