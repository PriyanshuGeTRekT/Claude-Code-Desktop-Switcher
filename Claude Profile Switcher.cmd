@echo off
rem Double-click launcher for the Claude Profile Switcher window.
rem Deliberately no -WindowStyle Hidden: that flag propagates through STARTUPINFO and
rem WinForms applies it to the first window it shows, leaving the app itself invisible.
rem The script hides its own console at startup instead.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSwitcher.ps1"
