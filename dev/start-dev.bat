@echo off
echo ================================================================
echo   BMW CarData Plugin - Local Development Server
echo ================================================================
echo.
echo Starting development server on http://localhost:8080/
echo.
echo Open your browser and navigate to:
echo   http://localhost:8080/dev/index-dev.cgi
echo.
echo Press Ctrl+C to stop the server.
echo.
echo ================================================================
echo.

cd /d "%~dp0\.."
perl dev\start-dev-server.pl
