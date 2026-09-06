@echo off
rem Double-click launcher for the Claude Profile Switcher window.
rem conhost --headless runs PowerShell with no console window at all, so nothing flashes.
start "" "%SystemRoot%\System32\conhost.exe" --headless "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSwitcher.ps1"
