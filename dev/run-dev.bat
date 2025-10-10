@echo off
REM Local Development - Run CGI script directly
REM This will output HTML to the console - redirect to a file and open in browser

cd /d "%~dp0"

echo Running BMW CarData Plugin Web Interface (Development Mode)
echo.
echo Output will be saved to: dev-output.html
echo.

perl index-dev.cgi > dev-output.html 2>&1

if %ERRORLEVEL% EQU 0 (
    echo.
    echo Success! Opening in default browser...
    start dev-output.html
) else (
    echo.
    echo Error running CGI script. Check console output above.
    pause
)
