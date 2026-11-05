# Tablero web NeoGrid

Flask + HTML/CSS/JavaScript propios (gráficos y diagramas en SVG, sin CDN). Dos motores de datos:

| `MODO_BD` | Uso | Datos |
|---|---|---|
| `mssql` | Computador de la maqueta (datos en vivo, sin internet) | SQL Server: NeoGridRelacional y NeoGridDW |
| `sqlite` | Nube (Render) | `datos/relacional.sqlite` y `datos/dw.sqlite`, copia de solo lectura |

## En el computador de la maqueta

```bat
cd C:\neogrid\neogrid_ecosistema\dashboard
py -3.13 -m pip install -r requirements-local.txt
copy .env.example .env        (deje MODO_BD=mssql)
py -3.13 run_local.py         (http://localhost:8000)
```

O doble clic en `..\maqueta\tablero_local.bat`.

## Copia para la nube

```bat
py -3.13 scripts\exportar_a_sqlite.py
```

Crea `datos\relacional.sqlite`, `datos\dw.sqlite` y `datos\neogrid_datos.zip`. Suba el zip como archivo
de una versión (release) del repositorio de GitHub y use su enlace como `DATOS_URL` en Render.
Para probar la copia en local: `set MODO_BD=sqlite` y `py -3.13 run_local.py`.

## Render

El archivo `render.yaml` de la raíz del repositorio crea el servicio (New → Blueprint):
`pip install -r requirements.txt && python scripts/descargar_datos.py` y
`gunicorn -w 1 --threads 4 -b 0.0.0.0:$PORT --timeout 120 app.main:app`.
Variables: `MODO_BD=sqlite`, `DATOS_URL` (enlace del zip), `CLAVE_INGESTA` (la genera Render; cópiela en
`C:\neogrid\puente.env`). Comprobación: `https://<servicio>.onrender.com/api/salud`.

## API

`/api/salud`, `/api/meta/info`, `/api/resumen`, `/api/red/noche`, `/api/luminarias`, `/api/luminaria/<id>`,
`/api/sensores`, `/api/operacion/perfil-horario`, `/api/operacion/estados`, `/api/operacion/mapa-calor`,
`/api/consumo`, `/api/fallas`, `/api/relacional/{resumen,mediciones,eventos,viviendas}`, `/api/dw/{resumen,cubo}`,
`/api/etl`, `/api/comparacion`, `/api/comparacion/consulta`,
`/api/explorar/<relacional|multidimensional>/{tablas,tabla/<t>,tabla/<t>/datos,diagrama}`,
`/api/maqueta/estado` (GET; POST con cabecera `X-API-Key`).

Filtros comunes: `desde`, `hasta` (AAAA-MM-DD), `zona` (OES, EST, AVC, HOS, PLZ, NRT), `ubicacion`, `luminaria`,
`origen` (FISICO, SIMULADO). Datos del explorador: `pagina`, `tam` (≤ 100), `orden`, `dir`, y hasta tres
`f=columna|operador|valor` con operadores `eq ne gt ge lt le contiene empieza nulo no_nulo`.
