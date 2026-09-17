@echo off
setlocal
set "MODE=%~1"
if "%MODE%"=="" set "MODE=debug"

if /i "%MODE%"=="debug" (
	odin build . -debug -vet -strict-style -out:sonar.exe
	exit /b %errorlevel%
)
if /i "%MODE%"=="release" (
	odin build . -o:speed -vet -strict-style -out:sonar.exe
	exit /b %errorlevel%
)
if /i "%MODE%"=="test" (
	odin test ntfs -vet -strict-style
	exit /b %errorlevel%
)
if /i "%MODE%"=="check" (
	odin check . -vet -strict-style
	exit /b %errorlevel%
)

echo usage: build [debug^|release^|test^|check]
exit /b 1
