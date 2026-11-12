# NeoGrid · Ecosistema de datos del alumbrado público inteligente

Proyecto del curso de Big Data (Universidad de Cundinamarca, Extensión Chía): maqueta física
(dos ESP32, MQTT, SQL Server) + modelo relacional, data warehouse, ETL (SSIS y T-SQL) y tablero
web desplegado en Render.

## Carpetas

| Carpeta | Contenido |
|---|---|
| `sql/` | Scripts para SSMS 22 (01 a 13) |
| `ssis/` | Proyecto de Visual Studio `NeoGrid_ETL` con el paquete `ETL_NeoGrid.dtsx` y su guía |
| `dashboard/` | Tablero web (Flask) y scripts de exportación y descarga de datos |
| `maqueta/` | Puente entre la maqueta y el ecosistema, lanzadores `.bat` |
| `render.yaml` | Blueprint de Render (despliegue en la nube) |

## Requisitos

- SQL Server 2022 o 2025 (probado en 2025 Standard Developer) y SSMS 22.
- Visual Studio 2022/2026 con la extensión *SQL Server Integration Services Projects* y el
  proveedor OLE DB **MSOLEDBSQL19**.
- Python 3.13 solo para el tablero y el puente de la maqueta.

## Reproducción desde cero

Ejecutar en SSMS, conectado a `localhost`, en este orden (F5 en cada archivo):

| # | Script | Resultado |
|---|---|---|
| 1 | `sql/01_relacional_esquema.sql` | crea NeoGridRelacional (borra la anterior si existe) |
| 2 | `sql/02_relacional_catalogos.sql` | zonas, 64 luminarias, 45 sensores, 24 viviendas, técnicos, tipos |
| 3 | `sql/03_relacional_generar_datos.sql` | 1.000.000 de mediciones simuladas, fallas, mantenimientos y eventos (3–10 min) |
| 4 | `sql/10_usuarios_procesos.sql` | usuarios, roles, procesos, responsabilidades y extracción de eventos |
| 5 | `sql/04_dw_esquema.sql` | crea NeoGridDW (borra la anterior si existe) |
| 6 | `sql/05_dw_dimensiones_fijas.sql` | calendario, intervalos de 15 min, calidad del dato |
| 7 | `sql/11_dw_eventos.sql` | estrella de eventos y control del ETL para eventos |
| 8 | `sql/06_etl_procedimientos.sql` | procedimientos del ETL (SSIS y T-SQL) |
| 9 | `sql/07_integracion_maqueta.sql` | importación desde NeoGridAlumbrado (no la modifica) |
| 10 | ETL | paquete SSIS (abajo) **o** `EXEC NeoGridDW.dbo.sp_etl_ejecutar_tsql;` |
| 11 | `sql/08_validacion.sql` | 42 pruebas; todas deben decir PASA |
| 12 | `sql/09_prueba_rechazos_etl.sql` | prueba de reglas de calidad; luego `EXEC NeoGridDW.dbo.sp_etl_limpiar_prueba;` |
| 13 | `sql/12_evidencias_informe.sql` y `sql/13_consultas_analiticas.sql` | evidencias y consultas analíticas del informe |

Para actualizar una instalación que ya tiene los datos (sin regenerar el millón de mediciones):
`10` → `11` → `06` → `EXEC NeoGridDW.dbo.sp_etl_reiniciar;` → ETL → `08`.

Si se vuelve a ejecutar `03`, ejecute otra vez `10` (reasigna los usuarios de las fallas y los
mantenimientos simulados).

## ETL con SSIS

1. Abrir `ssis/NeoGrid_ETL/NeoGrid_ETL.slnx` en Visual Studio.
2. Revisar que `CM_Relacional` y `CM_DW` apunten a `localhost` (*Trust server certificate* activo).
3. Ejecutar el paquete `ETL_NeoGrid.dtsx` (F5). Flujo de control:
   `SQL_IniciarEjecucion → SQL_CargarDimensiones → DFT_HechosOperacion → DFT_Eventos →
   SQL_HechosSecundarios → SQL_Agregados → SQL_Finalizar` (con `SQL_RegistrarError` en OnError).
4. Volver a ejecutarlo no duplica datos: las marcas de agua dejan la ventana vacía y las búsquedas
   `LKP_YaCargado` / `LKP_Grano` y los índices únicos impiden repetir filas.
5. Carga completa de nuevo: `EXEC NeoGridDW.dbo.sp_etl_reiniciar;` y ejecutar el paquete.

Detalle de cada componente: `ssis/GUIA_SSIS.md`.

## Tablero y maqueta

- Tablero local: `dashboard/README.md`.
- Nube: `dashboard/scripts/exportar_a_sqlite.py`, versión de GitHub con `neogrid_datos.zip`,
  Blueprint en Render (https://neogrid-alumbrado.onrender.com).
- Maqueta: `maqueta/puente.env.example` → `C:\neogrid\puente.env`; `maqueta/iniciar_neogrid.bat`.
  El puente importa los datos físicos y ejecuta el ETL T-SQL incremental. Ciérrelo antes de una
  ejecución de SSIS que se vaya a usar como evidencia, para que todos los conteos salgan de esa corrida.
