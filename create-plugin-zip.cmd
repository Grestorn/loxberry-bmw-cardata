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

REM Output filename
set ZIP_NAME=%PLUGIN_NAME%-%VERSION%.zip

echo Creating plugin ZIP archive: %ZIP_NAME%
echo Plugin: %PLUGIN_NAME%
echo Version: %VERSION%
echo.

REM Remove old ZIP if it exists
if exist "%ZIP_NAME%" del "%ZIP_NAME%"

echo Copying Git-tracked files...

REM Create temporary directory
set TEMP_DIR=%TEMP%\loxberry-plugin-%RANDOM%
mkdir "%TEMP_DIR%\%PLUGIN_NAME%"

REM Use git archive to export all tracked files
git archive HEAD | tar -x -C "%TEMP_DIR%\%PLUGIN_NAME%"

REM Create ZIP archive
cd /d "%TEMP_DIR%"
powershell -command "Compress-Archive -Path '%PLUGIN_NAME%' -DestinationPath '%ZIP_NAME%' -Force"

REM Move ZIP to original directory
move "%ZIP_NAME%" "%~dp0" > nul

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