"""Ejecuta el tablero en este computador.

    py -3.13 run_local.py            (http://localhost:8000)

Con MODO_BD=sqlite usa la copia de datos/; con MODO_BD=mssql se conecta a SQL Server
(NeoGridRelacional y NeoGridDW) y muestra la maqueta en vivo sin pasar por la nube.
La configuración se lee de las variables de entorno o del archivo .env (vea .env.example).
"""
import os

from app.main import app

if __name__ == "__main__":
    puerto = int(os.environ.get("PORT", "8000"))
    try:
        from waitress import serve

        print(f"NeoGrid en http://localhost:{puerto}  (Ctrl+C para detener)")
        serve(app, host="0.0.0.0", port=puerto, threads=6)
    except ImportError:
        app.run(host="0.0.0.0", port=puerto, threaded=True)
