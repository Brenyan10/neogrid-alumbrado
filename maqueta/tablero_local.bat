@echo off
title NeoGrid - tablero local
rem Tablero conectado directo a SQL Server (datos en vivo, sin internet)
cd /d C:\neogrid\neogrid_ecosistema\dashboard
set MODO_BD=mssql
start "" http://localhost:8000
py -3.13 run_local.py
pause
