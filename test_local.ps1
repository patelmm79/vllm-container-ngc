# Test runner for Windows without gcloud installed
#
# Usage:
#   1. Copy .env.test.example to .env.test
#   2. Fill in SERVICE_URL and AUTH_TOKEN in .env.test
#   3. Run: .\test_local.ps1

Write-Host "Loading test environment variables from .env.test..." -ForegroundColor Cyan

if (-not (Test-Path ".env.test")) {
    Write-Host "Error: .env.test file not found" -ForegroundColor Red
    Write-Host "Please copy .env.test.example to .env.test and fill in your values" -ForegroundColor Yellow
    exit 1
}

# Load environment variables from .env.test
Get-Content .env.test | ForEach-Object {
    $line = $_.Trim()
    # Skip comments and empty lines
    if ($line -and -not $line.StartsWith("#")) {
        if ($line -match "^([^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Write-Host "  Setting $key" -ForegroundColor Gray
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

Write-Host "`nRunning pytest..." -ForegroundColor Cyan
pytest test_endpoint.py -v

Write-Host "`nTest complete!" -ForegroundColor Green
