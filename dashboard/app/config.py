"""Configuración del tablero NeoGrid (solo variables de entorno; nada sensible en el código)."""
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent


def _cargar_env(ruta: Path) -> None:
    """Lee un archivo .env sencillo (CLAVE=valor) sin sobrescribir variables ya definidas."""
    if not ruta.exists():
        return
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        os.environ.setdefault(clave.strip(), valor.strip().strip('"').strip("'"))


_cargar_env(BASE / ".env")

# sqlite: copia de solo lectura exportada desde SQL Server (despliegue en la nube)
# mssql:  conexión directa a SQL Server (computador de la maqueta, datos en vivo)
MODO_BD = os.environ.get("MODO_BD", "sqlite").strip().lower()
if MODO_BD not in ("sqlite", "mssql"):
    raise RuntimeError("MODO_BD debe ser 'sqlite' o 'mssql'")

RUTA_DATOS = Path(os.environ.get("RUTA_DATOS", str(BASE / "datos")))

MSSQL_SERVIDOR = os.environ.get("MSSQL_SERVIDOR", "localhost")
MSSQL_DRIVER = os.environ.get("MSSQL_DRIVER", "ODBC Driver 18 for SQL Server")
MSSQL_USUARIO = os.environ.get("MSSQL_USUARIO", "")      # vacío = autenticación de Windows
MSSQL_CLAVE = os.environ.get("MSSQL_CLAVE", "")
BD_RELACIONAL = os.environ.get("BD_RELACIONAL", "NeoGridRelacional")
BD_DW = os.environ.get("BD_DW", "NeoGridDW")

# Clave que debe enviar el puente de la maqueta en la cabecera X-API-Key.
# Si está vacía, la ingesta en vivo queda deshabilitada.
CLAVE_INGESTA = os.environ.get("CLAVE_INGESTA", "")

CACHE_SEGUNDOS = int(os.environ.get("CACHE_SEGUNDOS", "900" if MODO_BD == "sqlite" else "30"))
TIEMPO_MAX_CONSULTA = float(os.environ.get("TIEMPO_MAX_CONSULTA", "20"))
LIMITE_PETICIONES_MIN = int(os.environ.get("LIMITE_PETICIONES_MIN", "240"))
PRECALENTAR = os.environ.get("PRECALENTAR", "1") == "1"
VERSION = "1.0.0"
