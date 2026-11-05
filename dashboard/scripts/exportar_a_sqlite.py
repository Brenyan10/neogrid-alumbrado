"""Exporta NeoGridRelacional y NeoGridDW (SQL Server) a dos archivos SQLite de solo lectura.

Se ejecuta en el computador que tiene SQL Server (el de la maqueta):

    py -3.13 scripts\\exportar_a_sqlite.py                 (servidor localhost, autenticación de Windows)
    py -3.13 scripts\\exportar_a_sqlite.py --servidor .\\SQLEXPRESS --salida datos

Genera datos/relacional.sqlite, datos/dw.sqlite y datos/neogrid_datos.zip (el que se sube
a la versión de GitHub para el despliegue en la nube). Copia TODAS las tablas de las dos bases,
con sus filas, su clave primaria, sus claves foráneas (documentales) y sus índices; además copia
los metadatos de SQL Server (vistas vw_meta_*) para que el explorador web muestre los tipos
originales de SQL Server y no los de SQLite.
"""
from __future__ import annotations

import argparse
import datetime as dt
import decimal
import sqlite3
import sys
import time
import zipfile
from pathlib import Path

TIPOS_ENTEROS = {"bigint", "int", "smallint", "tinyint", "bit"}
TIPOS_REALES = {"decimal", "numeric", "float", "real", "money", "smallmoney"}
META = {
    "meta_tablas": ["tabla", "descripcion", "categoria", "filas", "columnas"],
    "meta_columnas": ["tabla", "orden", "columna", "tipo", "tipo_completo", "admite_nulos", "es_identidad", "es_pk", "es_fk",
                      "tabla_referenciada", "columna_referenciada"],
    "meta_relaciones": ["restriccion", "tabla_origen", "columna_origen", "tabla_destino", "columna_destino"],
    "meta_indices": ["tabla", "indice", "tipo", "es_unico", "es_pk", "columnas", "columnas_incluidas"],
}


def q(nombre: str) -> str:
    return '"' + nombre.replace('"', '""') + '"'


def tipo_sqlite(tipo_sql_server: str) -> str:
    t = (tipo_sql_server or "").lower()
    if t in TIPOS_ENTEROS:
        return "INTEGER"
    if t in TIPOS_REALES:
        return "REAL"
    return "TEXT"


def convertir(valor):
    if valor is None:
        return None
    if isinstance(valor, decimal.Decimal):
        return float(valor)
    if isinstance(valor, bool):
        return int(valor)
    if isinstance(valor, dt.datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(valor, (dt.date, dt.time)):
        return valor.isoformat()
    if isinstance(valor, (bytes, bytearray)):
        return bytes(valor).hex()
    return valor


def crear_sqlite(ruta: Path, meta: dict, proveedor_filas, info: dict) -> dict:
    """Crea un archivo SQLite a partir de los metadatos y un proveedor de filas.

    meta: {"meta_tablas": [...], "meta_columnas": [...], "meta_relaciones": [...], "meta_indices": [...]}
          (listas de diccionarios con las columnas de META)
    proveedor_filas(tabla, columnas, orden_pk) -> iterable de tuplas
    """
    if ruta.exists():
        ruta.unlink()
    cx = sqlite3.connect(ruta)
    cx.execute("PRAGMA journal_mode = OFF")
    cx.execute("PRAGMA synchronous = OFF")
    cx.execute("PRAGMA page_size = 4096")
    columnas_por_tabla: dict[str, list] = {}
    for c in sorted(meta["meta_columnas"], key=lambda x: (x["tabla"], int(x["orden"]))):
        columnas_por_tabla.setdefault(c["tabla"], []).append(c)
    pk_por_tabla = {i["tabla"]: [s.strip() for s in (i["columnas"] or "").split(",") if s.strip()]
                    for i in meta["meta_indices"] if int(i["es_pk"] or 0) == 1}
    fk_por_tabla: dict[str, list] = {}
    for r in meta["meta_relaciones"]:
        fk_por_tabla.setdefault(r["tabla_origen"], []).append(r)

    resumen = {}
    for t in meta["meta_tablas"]:
        nombre = t["tabla"]
        cols = columnas_por_tabla.get(nombre, [])
        pk = pk_por_tabla.get(nombre, [])
        definicion = []
        for c in cols:
            tipo = tipo_sqlite(c["tipo"])
            if len(pk) == 1 and c["columna"] == pk[0] and tipo == "INTEGER":
                definicion.append(f"{q(c['columna'])} INTEGER PRIMARY KEY")
            else:
                nulo = "" if int(c["admite_nulos"] or 0) else " NOT NULL"
                definicion.append(f"{q(c['columna'])} {tipo}{nulo}")
        if pk and not (len(pk) == 1 and tipo_sqlite(next((c["tipo"] for c in cols if c["columna"] == pk[0]), "")) == "INTEGER"):
            definicion.append(f"PRIMARY KEY ({', '.join(q(x) for x in pk)})")
        for r in fk_por_tabla.get(nombre, []):
            definicion.append(f"FOREIGN KEY ({q(r['columna_origen'])}) REFERENCES {q(r['tabla_destino'])} ({q(r['columna_destino'])})")
        cx.execute(f"CREATE TABLE {q(nombre)} (\n  " + ",\n  ".join(definicion) + "\n)")

        nombres = [c["columna"] for c in cols]
        marcas = ", ".join("?" for _ in nombres)
        insertar = f"INSERT INTO {q(nombre)} ({', '.join(q(x) for x in nombres)}) VALUES ({marcas})"
        inicio, n, lote = time.perf_counter(), 0, []
        for fila in proveedor_filas(nombre, nombres, pk):
            lote.append(tuple(convertir(v) for v in fila))
            if len(lote) >= 20000:
                cx.executemany(insertar, lote)
                n += len(lote)
                lote.clear()
        if lote:
            cx.executemany(insertar, lote)
            n += len(lote)
        cx.commit()
        resumen[nombre] = n
        print(f"   {nombre:<32} {n:>10,} filas  ({time.perf_counter() - inicio:.1f} s)".replace(",", "."), flush=True)

    # Índices (los columnstore no existen en SQLite: sus consultas usan los índices de fila)
    usados = set()
    for i in meta["meta_indices"]:
        if int(i["es_pk"] or 0) == 1 or "COLUMNSTORE" in (i["tipo"] or "").upper():
            continue
        cols = [s.strip() for s in (i["columnas"] or "").split(",") if s.strip()]
        if not cols:
            continue
        unico = int(i["es_unico"] or 0) == 1
        if not unico and i.get("columnas_incluidas"):
            cols += [s.strip() for s in i["columnas_incluidas"].split(",") if s.strip() and s.strip() not in cols]
        nombre_idx = f"{i['tabla']}__{i['indice']}"
        if nombre_idx in usados:
            continue
        usados.add(nombre_idx)
        cx.execute(f"CREATE {'UNIQUE ' if unico else ''}INDEX {q(nombre_idx)} ON {q(i['tabla'])} ({', '.join(q(c) for c in cols)})")
    cx.commit()

    # Metadatos de SQL Server para el explorador
    for tabla_meta, columnas in META.items():
        cx.execute(f"CREATE TABLE {tabla_meta} ({', '.join(q(c) for c in columnas)})")
        filas = []
        for x in meta[tabla_meta]:
            fila = [x.get(c) for c in columnas]
            if tabla_meta == "meta_tablas":
                fila[columnas.index("filas")] = resumen.get(x["tabla"], x.get("filas"))
            filas.append(tuple(convertir(v) for v in fila))
        cx.executemany(f"INSERT INTO {tabla_meta} VALUES ({', '.join('?' for _ in columnas)})", filas)
    cx.execute("CREATE TABLE snapshot_info (clave TEXT PRIMARY KEY, valor TEXT)")
    cx.executemany("INSERT INTO snapshot_info VALUES (?, ?)", [(k, str(v)) for k, v in info.items()])
    cx.commit()
    print("   Estadísticas para el optimizador (ANALYZE)...", flush=True)
    cx.execute("ANALYZE")
    cx.commit()
    cx.close()
    return resumen


def _conectar(servidor: str, base: str, driver: str, usuario: str | None, clave: str | None):
    import pyodbc

    partes = [f"DRIVER={{{driver}}}", f"SERVER={servidor}", f"DATABASE={base}", "TrustServerCertificate=yes"]
    partes += [f"UID={usuario}", f"PWD={clave}"] if usuario else ["Trusted_Connection=yes"]
    return pyodbc.connect(";".join(partes), autocommit=True)


def _leer(cx, sql: str) -> list[dict]:
    cur = cx.cursor()
    cur.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, fila)) for fila in cur.fetchall()]


def exportar_base(servidor, base, ruta, driver, usuario, clave):
    print(f"\n== {base} -> {ruta.name}", flush=True)
    cx = _conectar(servidor, base, driver, usuario, clave)
    meta = {
        "meta_tablas": _leer(cx, "SELECT tabla, descripcion, categoria, filas, columnas FROM dbo.vw_meta_tablas"),
        "meta_columnas": _leer(cx, "SELECT * FROM dbo.vw_meta_columnas"),
        "meta_relaciones": _leer(cx, "SELECT * FROM dbo.vw_meta_relaciones"),
        "meta_indices": _leer(cx, "SELECT * FROM dbo.vw_meta_indices"),
    }
    version = _leer(cx, "SELECT @@VERSION AS v, @@SERVERNAME AS s")[0]

    def filas(tabla, columnas, pk):
        cur = cx.cursor()
        orden = f" ORDER BY {', '.join('[' + c + ']' for c in pk)}" if pk else ""
        cur.execute(f"SELECT {', '.join('[' + c + ']' for c in columnas)} FROM dbo.[{tabla}]{orden}")
        while True:
            bloque = cur.fetchmany(20000)
            if not bloque:
                break
            yield from bloque

    info = {"fecha_exportacion": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "servidor": version["s"],
            "base_origen": base, "version_sql_server": version["v"].split("\n")[0]}
    resumen = crear_sqlite(ruta, meta, filas, info)
    cx.close()
    return resumen


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--servidor", default="localhost")
    p.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    p.add_argument("--usuario", default=None, help="vacío = autenticación de Windows")
    p.add_argument("--clave", default=None)
    p.add_argument("--salida", default=str(Path(__file__).resolve().parent.parent / "datos"))
    p.add_argument("--sin-zip", action="store_true")
    a = p.parse_args()

    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    inicio = time.perf_counter()
    try:
        exportar_base(a.servidor, "NeoGridRelacional", salida / "relacional.sqlite", a.driver, a.usuario, a.clave)
        exportar_base(a.servidor, "NeoGridDW", salida / "dw.sqlite", a.driver, a.usuario, a.clave)
    except ImportError:
        print("Falta pyodbc: py -3.13 -m pip install pyodbc", file=sys.stderr)
        return 1
    if not a.sin_zip:
        destino = salida / "neogrid_datos.zip"
        print(f"\nComprimiendo {destino.name}...", flush=True)
        with zipfile.ZipFile(destino, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for nombre in ("relacional.sqlite", "dw.sqlite"):
                z.write(salida / nombre, nombre)
        print(f"   {destino.stat().st_size / 1e6:.1f} MB")
    print(f"\nListo en {time.perf_counter() - inicio:.0f} s. Archivos en {salida}")
    print("Siguiente paso: suba neogrid_datos.zip a una versión (release) de GitHub y copie su enlace en DATOS_URL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
