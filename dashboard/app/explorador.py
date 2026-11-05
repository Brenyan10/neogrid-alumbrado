"""Explorador de los dos modelos: estructura (tablas, columnas, claves, índices,
relaciones), datos paginados en el servidor con filtros y orden, y diagrama.

Seguridad: los nombres de tablas y columnas se validan contra los metadatos
(lista blanca) y los valores viajan siempre como parámetros.
"""
from __future__ import annotations

import re

from . import cache
from .db import ConsultaCostosa, bd

MODELOS = {"relacional": "rel", "multidimensional": "dw"}
OPERADORES = {
    "eq": "=", "ne": "<>", "gt": ">", "ge": ">=", "lt": "<", "le": "<=",
    "contiene": "LIKE", "empieza": "LIKE", "nulo": "IS NULL", "no_nulo": "IS NOT NULL",
}
TIPOS_ENTEROS = {"bigint", "int", "smallint", "tinyint", "bit"}
TIPOS_DECIMALES = {"decimal", "numeric", "float", "real", "money"}
TIPOS_FECHA = {"date", "datetime", "datetime2", "smalldatetime", "time"}
_RE_FECHA = re.compile(r"^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$")


class ErrorExplorador(ValueError):
    pass


def _modelo(nombre: str) -> str:
    if nombre not in MODELOS:
        raise ErrorExplorador("Modelo desconocido: use 'relacional' o 'multidimensional'.")
    return MODELOS[nombre]


def estructura(modelo_nombre: str) -> dict:
    m = _modelo(modelo_nombre)

    def calcular():
        tablas = bd.consultar(m, f"SELECT tabla, descripcion, categoria, filas, columnas FROM {bd.meta('meta_tablas')} ORDER BY tabla")
        columnas = bd.consultar(m, f"""SELECT tabla, orden, columna, tipo, tipo_completo, admite_nulos, es_identidad, es_pk, es_fk,
                                              tabla_referenciada, columna_referenciada
                                       FROM {bd.meta('meta_columnas')} ORDER BY tabla, orden""")
        relaciones = bd.consultar(m, f"""SELECT restriccion, tabla_origen, columna_origen, tabla_destino, columna_destino
                                         FROM {bd.meta('meta_relaciones')} ORDER BY tabla_origen, columna_origen""")
        indices = bd.consultar(m, f"""SELECT tabla, indice, tipo, es_unico, es_pk, columnas, columnas_incluidas
                                      FROM {bd.meta('meta_indices')} ORDER BY tabla, indice""")
        por_tabla: dict[str, list] = {}
        for c in columnas:
            por_tabla.setdefault(c["tabla"], []).append(c)
        indexadas: dict[str, set] = {}
        for i in indices:
            primera = (i["columnas"] or "").split(",")[0].strip()
            if primera:
                indexadas.setdefault(i["tabla"], set()).add(primera)
        return {"tablas": tablas, "columnas": por_tabla, "relaciones": relaciones, "indices": indices,
                "indexadas": {k: sorted(v) for k, v in indexadas.items()}}
    return cache.obtener(("estructura", m), calcular, 3600 if bd.dialecto == "sqlite" else 120)


def tablas(modelo_nombre: str) -> dict:
    e = estructura(modelo_nombre)
    return {"modelo": modelo_nombre, "tablas": e["tablas"],
            "totales": {"tablas": len(e["tablas"]), "filas": sum(int(t["filas"] or 0) for t in e["tablas"]),
                        "relaciones": len(e["relaciones"]), "indices": len(e["indices"])}}


def tabla(modelo_nombre: str, nombre: str) -> dict:
    e = estructura(modelo_nombre)
    info = next((t for t in e["tablas"] if t["tabla"] == nombre), None)
    if info is None:
        raise ErrorExplorador("La tabla no existe en este modelo.")
    return {
        "modelo": modelo_nombre, "tabla": info,
        "columnas": e["columnas"].get(nombre, []),
        "relaciones_salientes": [r for r in e["relaciones"] if r["tabla_origen"] == nombre],
        "relaciones_entrantes": [r for r in e["relaciones"] if r["tabla_destino"] == nombre],
        "indices": [i for i in e["indices"] if i["tabla"] == nombre],
        "columnas_indexadas": e["indexadas"].get(nombre, []),
    }


def _convertir(valor: str, tipo: str):
    valor = (valor or "").strip()
    if tipo in TIPOS_ENTEROS:
        try:
            return int(valor)
        except ValueError as error:
            raise ErrorExplorador(f"'{valor[:20]}' no es un número entero.") from error
    if tipo in TIPOS_DECIMALES:
        try:
            return float(valor.replace(",", "."))
        except ValueError as error:
            raise ErrorExplorador(f"'{valor[:20]}' no es un número.") from error
    if tipo in TIPOS_FECHA:
        if not _RE_FECHA.match(valor):
            raise ErrorExplorador("Las fechas se escriben AAAA-MM-DD o AAAA-MM-DD hh:mm.")
        return valor if len(valor) != 16 else valor + ":00"
    return valor[:100]


def datos(modelo_nombre: str, nombre: str, args) -> dict:
    m = _modelo(modelo_nombre)
    det = tabla(modelo_nombre, nombre)
    cols = det["columnas"]
    por_nombre = {c["columna"]: c for c in cols}
    q = bd.identificador

    try:
        pagina = max(1, int(args.get("pagina", 1)))
    except ValueError:
        pagina = 1
    try:
        tam = min(100, max(5, int(args.get("tam", 25))))
    except ValueError:
        tam = 25

    # Filtros: f=columna|operador|valor (hasta 3)
    condiciones, params, eco = [], [], []
    for crudo in args.getlist("f")[:3]:
        partes = crudo.split("|", 2)
        if len(partes) < 2:
            continue
        col, op = partes[0], partes[1]
        valor = partes[2] if len(partes) > 2 else ""
        if col not in por_nombre or op not in OPERADORES:
            raise ErrorExplorador("Filtro no válido.")
        tipo = (por_nombre[col]["tipo"] or "").lower()
        if op in ("nulo", "no_nulo"):
            condiciones.append(f"{q(col)} {OPERADORES[op]}")
        elif op in ("contiene", "empieza"):
            condiciones.append(f"{q(col)} LIKE ?")
            texto = str(valor)[:100].replace("[", "[[]") if bd.dialecto == "mssql" else str(valor)[:100]
            params.append(f"%{texto}%" if op == "contiene" else f"{texto}%")
        else:
            condiciones.append(f"{q(col)} {OPERADORES[op]} ?")
            params.append(_convertir(valor, tipo))
        eco.append({"columna": col, "operador": op, "valor": valor})
    where = (" WHERE " + " AND ".join(condiciones)) if condiciones else ""

    pk = [c["columna"] for c in cols if c["es_pk"]] or [cols[0]["columna"]]
    orden = args.get("orden") if args.get("orden") in por_nombre else None
    direccion = "DESC" if str(args.get("dir", "asc")).lower() == "desc" else "ASC"
    claves_orden = ([f"{q(orden)} {direccion}"] if orden else []) + [f"{q(c)} {direccion if not orden else 'ASC'}" for c in pk if c != orden]
    lista_cols = ", ".join(q(c["columna"]) for c in cols)
    sql = f"SELECT {lista_cols} FROM {q(nombre)}{where} ORDER BY {', '.join(claves_orden)}"
    sql_pag, p_pag = bd.paginar(sql, tam, (pagina - 1) * tam)
    try:
        filas, ms = bd.medir(m, sql_pag, params + list(p_pag), limite_seg=12)
    except ConsultaCostosa as error:
        indexadas = ", ".join(det["columnas_indexadas"]) or "la clave primaria"
        raise ErrorExplorador(
            f"La consulta tardó demasiado. Filtre u ordene por una columna indexada ({indexadas}) para recorrer "
            f"esta tabla de {int(det['tabla']['filas'] or 0):,} filas.".replace(",", ".")) from error

    if not condiciones:
        total, exacto = det["tabla"]["filas"], True
    else:
        def contar():
            try:
                return bd.uno(m, f"SELECT COUNT(*) AS n FROM {q(nombre)}{where}", params).get("n")
            except ConsultaCostosa:
                return None
        total = cache.obtener(("contar", m, nombre, where, tuple(map(str, params))), contar)
        exacto = total is not None
    return {"modelo": modelo_nombre, "tabla": nombre, "pagina": pagina, "tam": tam, "total": total, "total_exacto": exacto,
            "orden": orden, "dir": direccion.lower(), "filtros": eco, "columnas": [c["columna"] for c in cols],
            "filas": [[f[c["columna"]] for c in cols] for f in filas], "ms": ms, "sql": sql}


def diagrama(modelo_nombre: str) -> dict:
    e = estructura(modelo_nombre)
    nodos = []
    for t in e["tablas"]:
        columnas = [{"nombre": c["columna"], "tipo": c["tipo_completo"], "pk": bool(c["es_pk"]), "fk": bool(c["es_fk"]),
                     "nulo": bool(c["admite_nulos"])} for c in e["columnas"].get(t["tabla"], [])]
        nodos.append({"id": t["tabla"], "categoria": t["categoria"], "filas": t["filas"], "descripcion": t["descripcion"],
                      "columnas": columnas})
    aristas = [{"id": r["restriccion"], "origen": r["tabla_origen"], "col_origen": r["columna_origen"],
                "destino": r["tabla_destino"], "col_destino": r["columna_destino"]} for r in e["relaciones"]]
    return {"modelo": modelo_nombre, "tipo": "er" if modelo_nombre == "relacional" else "estrella",
            "nodos": nodos, "aristas": aristas}
