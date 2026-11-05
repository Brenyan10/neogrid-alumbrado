"""Acceso a datos con dos motores intercambiables.

* SQLite: copia de solo lectura de NeoGridRelacional y NeoGridDW (archivos
  relacional.sqlite y dw.sqlite generados por scripts/exportar_a_sqlite.py).
* SQL Server: conexión directa con pyodbc (modo en vivo junto a la maqueta).

Las consultas se escriben en SQL portable; las pocas diferencias de dialecto
(paginación, extracción de fecha y hora, nombres de las vistas de metadatos)
se resuelven con los métodos de esta clase.
"""
from __future__ import annotations

import datetime as dt
import decimal
import sqlite3
import threading
import time

from . import config

MODELOS = ("rel", "dw")


class ConsultaCostosa(Exception):
    """La consulta superó el tiempo máximo permitido."""


class DatosNoDisponibles(Exception):
    """No hay archivos de datos o no se pudo conectar a SQL Server."""


def _normalizar(valor):
    if isinstance(valor, decimal.Decimal):
        return float(valor)
    if isinstance(valor, dt.datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(valor, dt.date):
        return valor.strftime("%Y-%m-%d")
    if isinstance(valor, bool):
        return int(valor)
    if isinstance(valor, (bytes, bytearray)):
        return valor.hex()
    return valor


class BaseDatos:
    def __init__(self) -> None:
        self.dialecto = config.MODO_BD
        self._local = threading.local()
        if self.dialecto == "sqlite":
            self._rutas = {
                "rel": config.RUTA_DATOS / "relacional.sqlite",
                "dw": config.RUTA_DATOS / "dw.sqlite",
            }

    # ------------------------------------------------------------------ conexión
    def disponible(self) -> bool:
        if self.dialecto == "sqlite":
            return all(r.exists() for r in self._rutas.values())
        try:
            self.consultar("rel", "SELECT 1 AS ok")
            return True
        except Exception:
            return False

    def _conexion(self, modelo: str):
        if modelo not in MODELOS:
            raise ValueError("modelo desconocido")
        conexiones = getattr(self._local, "conexiones", None)
        if conexiones is None:
            conexiones = self._local.conexiones = {}
        cx = conexiones.get(modelo)
        if cx is not None:
            return cx
        if self.dialecto == "sqlite":
            ruta = self._rutas[modelo]
            if not ruta.exists():
                raise DatosNoDisponibles(
                    f"No se encontró {ruta.name}. Ejecute scripts/descargar_datos.py o scripts/exportar_a_sqlite.py.")
            uri = f"file:{ruta.as_posix()}?mode=ro&immutable=1"
            cx = sqlite3.connect(uri, uri=True, check_same_thread=False)
            cx.execute("PRAGMA cache_size = -16000")
            cx.execute("PRAGMA temp_store = FILE")
            cx.execute("PRAGMA query_only = ON")
        else:
            import pyodbc  # solo se necesita en modo SQL Server

            base = config.BD_RELACIONAL if modelo == "rel" else config.BD_DW
            partes = [f"DRIVER={{{config.MSSQL_DRIVER}}}", f"SERVER={config.MSSQL_SERVIDOR}",
                      f"DATABASE={base}", "TrustServerCertificate=yes", "APP=NeoGrid-Tablero"]
            if config.MSSQL_USUARIO:
                partes += [f"UID={config.MSSQL_USUARIO}", f"PWD={config.MSSQL_CLAVE}"]
            else:
                partes.append("Trusted_Connection=yes")
            try:
                cx = pyodbc.connect(";".join(partes), autocommit=True, timeout=10)
            except pyodbc.Error as error:
                raise DatosNoDisponibles(f"No se pudo conectar a SQL Server ({base}): {error}") from error
            cx.timeout = int(config.TIEMPO_MAX_CONSULTA)
        conexiones[modelo] = cx
        return cx

    def _descartar(self, modelo: str) -> None:
        conexiones = getattr(self._local, "conexiones", {})
        cx = conexiones.pop(modelo, None)
        if cx is not None:
            try:
                cx.close()
            except Exception:
                pass

    # ------------------------------------------------------------------ consultas
    def consultar(self, modelo: str, sql: str, params=(), limite_seg: float | None = None) -> list[dict]:
        limite = limite_seg or config.TIEMPO_MAX_CONSULTA
        cx = self._conexion(modelo)
        if self.dialecto == "sqlite":
            fin = time.monotonic() + limite
            cx.set_progress_handler(lambda: 1 if time.monotonic() > fin else 0, 20000)
            try:
                cur = cx.execute(sql, tuple(params))
                columnas = [c[0] for c in cur.description] if cur.description else []
                filas = cur.fetchall()
            except sqlite3.OperationalError as error:
                if "interrupted" in str(error):
                    raise ConsultaCostosa() from error
                raise
            finally:
                cx.set_progress_handler(None, 0)
        else:
            import pyodbc

            try:
                cur = cx.cursor()
                cur.execute(sql, *params) if params else cur.execute(sql)
                while cur.description is None and cur.nextset():
                    pass
                columnas = [c[0] for c in cur.description] if cur.description else []
                filas = cur.fetchall() if columnas else []
                cur.close()
            except pyodbc.OperationalError as error:
                self._descartar(modelo)
                if "HYT00" in str(error) or "timeout" in str(error).lower():
                    raise ConsultaCostosa() from error
                raise DatosNoDisponibles(str(error)) from error
            except pyodbc.Error as error:
                if "08S01" in str(error) or "08001" in str(error):
                    self._descartar(modelo)
                    raise DatosNoDisponibles(str(error)) from error
                raise
        return [{c: _normalizar(v) for c, v in zip(columnas, fila)} for fila in filas]

    def uno(self, modelo: str, sql: str, params=()) -> dict:
        filas = self.consultar(modelo, sql, params)
        return filas[0] if filas else {}

    def medir(self, modelo: str, sql: str, params=(), limite_seg: float | None = None):
        inicio = time.perf_counter()
        filas = self.consultar(modelo, sql, params, limite_seg)
        return filas, round((time.perf_counter() - inicio) * 1000, 1)

    # ------------------------------------------------------------------ dialecto
    def paginar(self, sql_ordenado: str, limite: int, desplazamiento: int = 0):
        """Agrega la paginación a una consulta que ya termina en ORDER BY."""
        if self.dialecto == "sqlite":
            return f"{sql_ordenado} LIMIT ? OFFSET ?", (int(limite), int(desplazamiento))
        return f"{sql_ordenado} OFFSET ? ROWS FETCH NEXT ? ROWS ONLY", (int(desplazamiento), int(limite))

    def dia(self, columna: str) -> str:
        if self.dialecto == "sqlite":
            return f"substr({columna}, 1, 10)"
        return f"CONVERT(char(10), {columna}, 23)"

    def hora(self, columna: str) -> str:
        if self.dialecto == "sqlite":
            return f"CAST(substr({columna}, 12, 2) AS INTEGER)"
        return f"DATEPART(HOUR, {columna})"

    def meta(self, nombre: str) -> str:
        """meta_tablas en SQLite equivale a la vista dbo.vw_meta_tablas en SQL Server."""
        return nombre if self.dialecto == "sqlite" else f"vw_{nombre}"

    def identificador(self, nombre: str) -> str:
        return f'"{nombre}"' if self.dialecto == "sqlite" else f"[{nombre}]"

    def info_motor(self) -> dict:
        if self.dialecto == "sqlite":
            try:
                filas = self.consultar("dw", "SELECT clave, valor FROM snapshot_info")
                info = {f["clave"]: f["valor"] for f in filas}
            except Exception:
                info = {}
            info["motor"] = f"SQLite {sqlite3.sqlite_version} (copia de solo lectura)"
            return info
        fila = self.uno("rel", "SELECT @@VERSION AS version, @@SERVERNAME AS servidor, SYSDATETIME() AS ahora")
        return {"motor": (fila.get("version") or "").split("\n")[0], "servidor": fila.get("servidor"),
                "fecha_exportacion": fila.get("ahora"), "origen": "SQL Server en vivo"}


bd = BaseDatos()
