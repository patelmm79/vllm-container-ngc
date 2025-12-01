@echo off
REM Test runner for Windows without gcloud installed
REM
REM Usage:
REM   1. Copy .env.test.example to .env.test
REM   2. Fill in SERVICE_URL and AUTH_TOKEN in .env.test
REM   3. Run: test_local.bat

echo Loading test environment variables from .env.test...

if not exist .env.test (
    echo Error: .env.test file not found
    echo Please copy .env.test.example to .env.test and fill in your values
    exit /b 1
)

REM Load environment variables from .env.test
for /f "tokens=1,* delims==" %%a in (.env.test) do (
    set "line=%%a"
    if not "!line:~0,1!"=="#" (
        set "%%a=%%b"
    )
)

echo Running pytest...
pytest test_endpoint.py -v

echo.
echo Test complete!
