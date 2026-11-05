@echo off
title NeoGrid - inicio
echo Iniciando Mosquitto...
start "Mosquitto" "C:\Program Files\mosquitto\mosquitto.exe" -c C:\neogrid\mosquitto.conf -v
timeout /t 3 /nobreak >nul
echo Iniciando suscriptor de Python...
start "Suscriptor" py -3.13 C:\neogrid\suscriptor_alumbrado.py
timeout /t 3 /nobreak >nul
echo Iniciando puente hacia las bases de datos y el tablero web...
start "Puente" py -3.13 C:\neogrid\puente_nube.py
echo.
echo IP del computador (debe coincidir con MQTT_HOST de los dos ESP32):
ipconfig | findstr IPv4
echo.
echo Deje abiertas las ventanas "Mosquitto", "Suscriptor" y "Puente". Ya puede cerrar esta.
pause
