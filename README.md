# NeoGrid · Ecosistema de datos del alumbrado público inteligente

Proyecto del curso de Big Data: maqueta física (dos ESP32, MQTT, SQL Server) + modelo relacional,
data warehouse, ETL (SSIS y T-SQL) y tablero web desplegable en Render.

## Carpetas

| Carpeta | Contenido |
|---|---|
| `sql/` | Scripts para SSMS 22, en orden de ejecución (01 a 09) |
| `ssis/` | Guía de construcción del paquete `ETL_NeoGrid.dtsx` |
| `dashboard/` | Tablero web (Flask) y scripts de exportación y descarga de datos |
| `maqueta/` | Puente entre la maqueta y el ecosistema, lanzadores `.bat` |
| `render.yaml` | Blueprint de Render (despliegue en la nube) |

## Orden de ejecución

1. `sql/01_relacional_esquema.sql` → NeoGridRelacional
2. `sql/02_relacional_catalogos.sql` → catálogos (64 luminarias, 45 sensores, 24 viviendas)
3. `sql/03_relacional_generar_datos.sql` → 1.000.000 de mediciones simuladas (3–10 min)
4. `sql/04_dw_esquema.sql` → NeoGridDW
5. `sql/05_dw_dimensiones_fijas.sql` → calendario, franjas y calidad
6. `sql/06_etl_procedimientos.sql` → procedimientos del ETL
7. `sql/07_integracion_maqueta.sql` → importación desde NeoGridAlumbrado (no la modifica)
8. Carga del DW: paquete SSIS (`ssis/GUIA_SSIS.md`) o `EXEC NeoGridDW.dbo.sp_etl_ejecutar_tsql;`
9. `sql/09_prueba_rechazos_etl.sql` → prueba de rechazos; luego `EXEC NeoGridDW.dbo.sp_etl_limpiar_prueba;`
10. `sql/08_validacion.sql` → 33 pruebas, todas deben decir PASA
11. Tablero local: `dashboard/README.md`
12. Nube: `dashboard/scripts/exportar_a_sqlite.py`, versión de GitHub con `neogrid_datos.zip`, Blueprint en Render
13. Maqueta: `maqueta/puente.env.example` → `C:\neogrid\puente.env`; `maqueta/iniciar_neogrid.bat`

El manual completo, con la arquitectura, los modelos, la práctica ETL, el despliegue y el plan de
pruebas, está en el documento «Ecosistema de datos · Alumbrado NeoGrid».
