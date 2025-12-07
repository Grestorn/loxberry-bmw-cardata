@echo off
REM Creates a ZIP archive containing only files tracked by Git
REM This archive can be uploaded to LoxBerry for testing

setlocal enabledelayedexpansion

REM Get the plugin name from plugin.cfg
for /f "tokens=2 delims==" %%a in ('findstr /b "FOLDER=" plugin.cfg') do set PLUGIN_NAME=%%a
if "%PLUGIN_NAME%"=="" set PLUGIN_NAME=bmw-cardata

REM Get version from plugin.cfg
for /f "tokens=2 delims==" %%a in ('findstr /b "VERSION=" plugin.cfg') do set VERSION=%%a
if "%VERSION%"=="" set VERSION=dev

REM Add snapshot suffix to version
set VERSION=%VERSION%-snapshot

REM Output filename
set ZIP_NAME=%PLUGIN_NAME%-%VERSION%.zip

echo Creating plugin ZIP archive: %ZIP_NAME%
echo Plugin: %PLUGIN_NAME%
echo Version: %VERSION%
echo.
echo NOTE: This creates a snapshot of the current working directory,
echo including uncommitted changes.
echo.

REM Remove old ZIP if it exists
if exist "%ZIP_NAME%" del "%ZIP_NAME%"

echo Copying current working directory files...

REM Create temporary directory
set TEMP_DIR=%TEMP%\loxberry-plugin-%RANDOM%
mkdir "%TEMP_DIR%\%PLUGIN_NAME%"

REM Copy all files except excluded directories using robocopy
REM /E = copy subdirectories including empty ones
REM /XD = exclude directories
REM /XF = exclude files
robocopy . "%TEMP_DIR%\%PLUGIN_NAME%" /E /XD .git .github .idea .claude node_modules dev /XF *.zip *.tar.gz package.json package-lock.json create-plugin-zip.cmd create-plugin-zip.sh create-plugin-zip.ps1 create-plugin-zip.exclude CLAUDE.md .gitignore > nul

REM robocopy returns 0-7 for success, >7 for errors
if %ERRORLEVEL% GEQ 8 (
    echo Error copying files
    rmdir /s /q "%TEMP_DIR%"
    exit /b 1
)

REM Create ZIP archive using tar (more compatible with Unix systems)
REM tar on Windows 10+ supports creating ZIP files with --format=zip
cd /d "%TEMP_DIR%"
tar -c -f "%~dp0%ZIP_NAME%" --format=zip "%PLUGIN_NAME%"

REM Cleanup
cd /d "%~dp0"
rmdir /s /q "%TEMP_DIR%"

echo.
echo Successfully created: %ZIP_NAME%
echo.
for %%A in ("%ZIP_NAME%") do echo File size: %%~zA bytes
echo.
echo You can now upload this file to LoxBerry for testing.

endlocal