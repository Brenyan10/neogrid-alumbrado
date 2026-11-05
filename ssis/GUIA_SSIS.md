# Paquete SSIS `ETL_NeoGrid.dtsx` — guía de construcción

El paquete carga el data warehouse **NeoGridDW** a partir de **NeoGridRelacional**.
Las reglas de negocio están en el flujo de datos del paquete (validación, limpieza,
imputación, cálculos y búsqueda de claves). Los procedimientos de `06_etl_procedimientos.sql`
se encargan del registro de la ejecución, las dimensiones (MERGE tipo 1), los hechos de
fallas y mantenimiento y los hechos agregados.

La misma lógica existe en T-SQL (`EXEC dbo.sp_etl_ejecutar_tsql;`) como plan B y para que
el puente de la maqueta pueda cargar datos nuevos sin abrir Visual Studio. Las dos rutas
escriben en las mismas tablas de control. Así se pueden comparar en el Monitor ETL del
tablero web (columna *herramienta*: `SSIS` o `TSQL`).

> **Paquete ya construido.** En esta carpeta está `ETL_NeoGrid.dtsx`, armado exactamente como
> describen las secciones 2 a 5. Para usarlo: cree el proyecto (sección 1, paso 1), en el
> *Explorador de soluciones* haga clic derecho en **Paquetes SSIS → Agregar paquete existente…**,
> elija *Sistema de archivos*, seleccione `C:\neogrid\neogrid_ecosistema\ssis\ETL_NeoGrid.dtsx`
> y borre el `Package.dtsx` vacío. Las conexiones usan *Microsoft OLE DB Driver 19 for SQL Server*;
> si su equipo tiene otra versión, abra `CM_DW` y `CM_Relacional`, elija el proveedor instalado,
> marque *Trust server certificate* y pruebe la conexión. Después siga con la sección 6.

---

## 0. Requisitos

| Elemento | Detalle |
|---|---|
| Visual Studio 2022 Community | Carga de trabajo «Almacenamiento y procesamiento de datos» |
| Extensión | *SQL Server Integration Services Projects 2022* (Marketplace de Visual Studio) |
| Proveedor OLE DB | *Microsoft OLE DB Driver for SQL Server* (MSOLEDBSQL). Si no aparece en la lista de proveedores, instale «Microsoft OLE DB Driver 19 for SQL Server». |
| Bases | `NeoGridRelacional` (scripts 01–03) y `NeoGridDW` (scripts 04–06) ya creadas |
| Servidor | `localhost` (instancia predeterminada de DESKTOP-NNM4AKS), autenticación de Windows |

> La versión de destino del proyecto es **SQL Server 2022** (*Propiedades del proyecto →
> Configuration Properties → General → TargetServerVersion*). El paquete se conecta por OLE DB,
> así que funciona contra el motor instalado (SQL Server 2025).
> El Agente SQL está deshabilitado en este equipo. Por eso el paquete se ejecuta desde
> Visual Studio (F5), o con `dtexec` si está instalado el componente Integration Services.

## 1. Crear el proyecto

1. *Archivo → Nuevo → Proyecto → Integration Services Project*. Nombre: `NeoGrid_ETL`, carpeta `C:\neogrid\ssis`.
2. Cambie el nombre de `Package.dtsx` a **`ETL_NeoGrid.dtsx`**.

## 2. Administradores de conexión

Panel *Connection Managers* → clic derecho → *New OLE DB Connection* → *New…*:

| Nombre | Proveedor | Servidor | Autenticación | Base | Opciones |
|---|---|---|---|---|---|
| `CM_Relacional` | Microsoft OLE DB Driver for SQL Server | `localhost` | Windows | `NeoGridRelacional` | *Trust server certificate* = True |
| `CM_DW` | Microsoft OLE DB Driver for SQL Server | `localhost` | Windows | `NeoGridDW` | *Trust server certificate* = True |

(Renómbrelos después de crearlos: clic derecho → *Rename*.)

## 3. Variables (ámbito: paquete)

*SSIS → Variables*:

| Nombre | Tipo | Valor | Expresión |
|---|---|---|---|
| `EjecucionId` | Int32 | 0 | |
| `WatermarkMin` | Int32 | 0 | |
| `WatermarkMax` | Int32 | 0 | |
| `ConsultaExtraccion` | String | | `"SELECT * FROM dbo.fn_etl_extraccion(" + (DT_WSTR,12)@[User::WatermarkMin] + ", " + (DT_WSTR,12)@[User::WatermarkMax] + ")"` |
| `FilasLeidas` | Int32 | 0 | |
| `FilasInsertadas` | Int32 | 0 | |
| `FilasRechazadas` | Int32 | 0 | |
| `FilasOmitidas` | Int32 | 0 | |

En `ConsultaExtraccion` marque **EvaluateAsExpression = True**.

## 4. Flujo de control (orden de ejecución)

```
SQL_IniciarEjecucion → SQL_CargarDimensiones → DFT_HechosOperacion
      → SQL_HechosSecundarios → SQL_Agregados → SQL_Finalizar
Controlador de eventos OnError (paquete) → SQL_RegistrarError
```

Una todas las tareas con restricciones de precedencia **Success** (flecha verde).

| Tarea (Execute SQL Task) | Conexión | SQLStatement | Parámetros (*Parameter Mapping*) | ResultSet |
|---|---|---|---|---|
| `SQL_IniciarEjecucion` | CM_DW | `EXEC dbo.sp_etl_iniciar @herramienta = 'SSIS', @paquete = N'ETL_NeoGrid.dtsx', @devolver_resultado = 1;` | — | **Single row**: `ejecucion_id` → `User::EjecucionId`, `watermark_min` → `User::WatermarkMin`, `watermark_max` → `User::WatermarkMax` |
| `SQL_CargarDimensiones` | CM_DW | `EXEC dbo.sp_etl_cargar_dimensiones @ejecucion_id = ?;` | `User::EjecucionId`, Input, LONG, nombre `0` | None |
| `SQL_HechosSecundarios` | CM_DW | `EXEC dbo.sp_etl_cargar_hechos_secundarios @ejecucion_id = ?;` | `User::EjecucionId`, Input, LONG, `0` | None |
| `SQL_Agregados` | CM_DW | `EXEC dbo.sp_etl_actualizar_agregados @ejecucion_id = ?;` | `User::EjecucionId`, Input, LONG, `0` | None |
| `SQL_Finalizar` | CM_DW | `EXEC dbo.sp_etl_finalizar @ejecucion_id = ?, @filas_leidas = ?, @filas_omitidas = ?;` | `0` = EjecucionId, `1` = FilasLeidas, `2` = FilasOmitidas (todos LONG) | None |

**Manejo de errores** — pestaña *Event Handlers*, ejecutable `ETL_NeoGrid`, evento **OnError**:
una Execute SQL Task `SQL_RegistrarError` (CM_DW):

```sql
EXEC dbo.sp_etl_registrar_error @ejecucion_id = ?, @mensaje = ?;
```

Parámetros: `0` = `User::EjecucionId` (LONG), `1` = `System::ErrorDescription` (NVARCHAR, tamaño 4000).
La ejecución queda en estado `FALLIDA`, con el mensaje y un paso `Error` en `etl_paso`.
Si el paquete falla antes de obtener el id, el procedimiento usa la última ejecución `EN_CURSO`.

## 5. Flujo de datos `DFT_HechosOperacion`

Propiedades de la tarea: `DefaultBufferMaxRows = 50000`, `AutoAdjustBufferSize = True`.

```
OLE_Origen_Mediciones
  → RC_Leidas
  → DC_Motivo
  → CS_Validacion ──(Rechazadas)───────────────────────────────┐
        │(Validas)                                              │
  → DC_Limpieza → DC_Calculos                                   │
  → LKP_Tiempo → LKP_Hora → LKP_Luminaria → LKP_Ubicacion       │
  → LKP_SensorLuz → LKP_SensorPresencia → LKP_Estado → LKP_Origen│
  → CS_Claves ──(SinDimension)→ DC_MotivoClave ─────────────────┤
        │(ConClaves)                                            │
  → LKP_YaCargado ──(Match)→ RC_Omitidas                        │
        │(No Match)                                             │
  → LKP_Grano ──(Match)→ DC_MotivoGrano ────────────────────────┤
        │(No Match)                                             │
  → RC_Insertadas → OLE_Destino_Hecho                           │
                                                                ▼
                          UNION_Rechazos → DC_Detalle → RC_Rechazadas → OLE_Destino_Rechazos
```

### 5.1 Extracción

**OLE_Origen_Mediciones** (OLE DB Source): conexión `CM_Relacional`.
*Data access mode* = **SQL command from variable**, variable `User::ConsultaExtraccion`.
La función `dbo.fn_etl_extraccion` devuelve solo las mediciones nuevas, con las columnas que el DW necesita:
`medicion_id, luminaria_id, ubicacion_id, sensor_luz_id, sensor_presencia_id, estado_id, origen_id,
fecha_hora, tiempo_key, hora_key, es_noche, nivel_luz_lux, lectura_ldr, detecciones, brillo_pct,
tension_v, corriente_a, potencia_w, energia_wh, temperatura_c, es_anomala, potencia_nominal_w,
lux_referencia, temperatura_ambiente, orden_duplicado`.
La ventana va de `WatermarkMin` (exclusivo) a `WatermarkMax` (inclusivo).

**RC_Leidas** (Row Count) → `User::FilasLeidas`.

### 5.2 Validación

**DC_Motivo** (Derived Column), *Add as new column* `motivo_validacion`, tipo **DT_WSTR (40)**:

```
orden_duplicado > 1 ? (DT_WSTR,40)"DUPLICADO" :
(fecha_hora < (DT_DBTIMESTAMP)"2026-01-01 00:00:00" || fecha_hora > DATEADD("dd", 1, GETDATE())) ? (DT_WSTR,40)"FECHA_INVALIDA" :
(ISNULL(brillo_pct) || brillo_pct < 0 || brillo_pct > 100) ? (DT_WSTR,40)"BRILLO_FUERA_DE_RANGO" :
((!ISNULL(tension_v) && (tension_v < 0 || tension_v > 400)) || (!ISNULL(nivel_luz_lux) && nivel_luz_lux < 0) || (!ISNULL(detecciones) && detecciones < 0) || (!ISNULL(potencia_w) && potencia_w < 0)) ? (DT_WSTR,40)"VALOR_IMPOSIBLE" :
(DT_WSTR,40)""
```

(Escríbala en una sola línea dentro del editor.)

**CS_Validacion** (Conditional Split):

| Orden | Salida | Condición |
|---|---|---|
| 1 | `Rechazadas` | `motivo_validacion != ""` |
| — | *Default output name*: `Validas` | |

### 5.3 Limpieza e imputación

**DC_Limpieza** (Derived Column) sobre la salida `Validas`, todas *Add as new column*:

| Columna | Tipo | Expresión |
|---|---|---|
| `lux_limpio` | DT_NUMERIC (9,1) | `ISNULL(nivel_luz_lux) ? (ISNULL(lux_referencia) ? (DT_NUMERIC,9,1)0 : (DT_NUMERIC,9,1)lux_referencia) : nivel_luz_lux` |
| `detecciones_limpias` | DT_I2 | `ISNULL(detecciones) ? (DT_I2)0 : detecciones` |
| `tension_limpia` | DT_NUMERIC (6,2) | `ISNULL(tension_v) ? (DT_NUMERIC,6,2)220 : tension_v` |
| `potencia_limpia` | DT_NUMERIC (8,2) | `ISNULL(potencia_w) ? (DT_NUMERIC,8,2)(potencia_nominal_w * brillo_pct / 100 + 1.5) : potencia_w` |
| `temperatura_limpia` | DT_NUMERIC (5,1) | `ISNULL(temperatura_c) ? (ISNULL(temperatura_ambiente) ? (DT_NUMERIC,5,1)14 : (DT_NUMERIC,5,1)temperatura_ambiente) : temperatura_c` |
| `fue_imputado` | DT_UI1 | `(ISNULL(nivel_luz_lux) || ISNULL(tension_v) || ISNULL(corriente_a) || ISNULL(potencia_w) || ISNULL(energia_wh) || ISNULL(temperatura_c) || ISNULL(detecciones) || (!ISNULL(energia_wh) && energia_wh < 0)) ? (DT_UI1)1 : (DT_UI1)0` |
| `encendida` | DT_UI1 | `brillo_pct > 0 ? (DT_UI1)1 : (DT_UI1)0` |
| `en_falla` | DT_UI1 | `(estado_id == 7 || estado_id == 8) ? (DT_UI1)1 : (DT_UI1)0` |
| `ejecucion_id` | DT_I4 | `@[User::EjecucionId]` |

**DC_Calculos** (Derived Column). Va en un componente aparte porque usa las columnas que crea `DC_Limpieza`:

| Columna | Tipo | Expresión |
|---|---|---|
| `energia_limpia` | DT_NUMERIC (10,3) | `(ISNULL(energia_wh) || energia_wh < 0) ? (DT_NUMERIC,10,3)(potencia_limpia * 0.25) : energia_wh` |
| `corriente_limpia` | DT_NUMERIC (7,3) | `!ISNULL(corriente_a) ? corriente_a : (tension_limpia > 0 ? (DT_NUMERIC,7,3)(potencia_limpia / tension_limpia) : (DT_NUMERIC,7,3)0)` |
| `energia_referencia_wh` | DT_NUMERIC (10,3) | `es_noche == 1 ? (DT_NUMERIC,10,3)((potencia_nominal_w + 1.5) * 0.25) : (DT_NUMERIC,10,3)0.375` |
| `ahorro_wh` | DT_NUMERIC (10,3) | `(DT_NUMERIC,10,3)((es_noche == 1 ? (potencia_nominal_w + 1.5) * 0.25 : 0.375) - ((ISNULL(energia_wh) || energia_wh < 0) ? potencia_limpia * 0.25 : energia_wh))` |
| `calidad_key` | DT_UI1 | `(DT_UI1)(1 + fue_imputado + 2 * es_anomala)` |

> **Referencia sin control adaptativo**: con 100 % de brillo toda la noche, `(potencia nominal + 1,5 W de control) × 0,25 h`.
> De día solo consume el control (1,5 W × 0,25 h = 0,375 Wh). El **ahorro** es la referencia menos la energía real.

### 5.4 Búsqueda de claves sustitutas

Ocho **Lookup** seguidos, todos con *Cache mode* = **Full cache**, conexión `CM_DW`,
*Specify how to handle rows with no matching entries* = **Ignore failure** (la clave queda NULL
y la revisa `CS_Claves`). En la pestaña *Connection* elija *Use results of an SQL query*:

| Lookup | Consulta | Unir por | Columna devuelta |
|---|---|---|---|
| `LKP_Tiempo` | `SELECT tiempo_key, tiempo_key AS tiempo_key_dim FROM dbo.dim_tiempo WHERE tiempo_key > 0` | `tiempo_key` | `tiempo_key_dim` |
| `LKP_Hora` | `SELECT hora_key, hora_key AS hora_key_dim FROM dbo.dim_hora` | `hora_key` | `hora_key_dim` |
| `LKP_Luminaria` | `SELECT luminaria_id, luminaria_key FROM dbo.dim_luminaria` | `luminaria_id` | `luminaria_key` |
| `LKP_Ubicacion` | `SELECT ubicacion_id, ubicacion_key FROM dbo.dim_ubicacion` | `ubicacion_id` | `ubicacion_key` |
| `LKP_SensorLuz` | `SELECT sensor_id, sensor_key AS sensor_luz_key FROM dbo.dim_sensor` | `sensor_luz_id` → `sensor_id` | `sensor_luz_key` |
| `LKP_SensorPresencia` | `SELECT sensor_id, sensor_key AS sensor_presencia_key FROM dbo.dim_sensor` | `sensor_presencia_id` → `sensor_id` | `sensor_presencia_key` |
| `LKP_Estado` | `SELECT estado_id, estado_key FROM dbo.dim_estado_operativo` | `estado_id` | `estado_key` |
| `LKP_Origen` | `SELECT origen_id, origen_key FROM dbo.dim_origen` | `origen_id` | `origen_key` |

Los tipos de las columnas de unión coinciden en el origen y en la dimensión
(SMALLINT ↔ DT_I2, TINYINT ↔ DT_UI1, INT ↔ DT_I4). El Lookup lo exige.

**CS_Claves** (Conditional Split):

| Salida | Condición |
|---|---|
| `SinDimension` | `ISNULL(tiempo_key_dim) || ISNULL(hora_key_dim) || ISNULL(luminaria_key) || ISNULL(ubicacion_key) || ISNULL(sensor_luz_key) || ISNULL(sensor_presencia_key) || ISNULL(estado_key) || ISNULL(origen_key)` |
| *Default*: `ConClaves` | |

**DC_MotivoClave** (Derived Column sobre `SinDimension`): *Replace* `motivo_validacion` = `(DT_WSTR,40)"CLAVE_SIN_DIMENSION"`.

### 5.5 Prevención de duplicados

**LKP_YaCargado** (Lookup, Full cache, CM_DW): consulta `SELECT medicion_id FROM dbo.fact_operacion_luminaria`.
Se une por `medicion_id` y no devuelve columnas. Configure *Redirect rows to no match output*.
- Salida **Match** → **RC_Omitidas** (Row Count → `User::FilasOmitidas`). Son filas que ya se cargaron en una ejecución anterior. No se rechazan, se omiten.
- Salida **No Match** → continúa.

**LKP_Grano** (Lookup, Full cache, CM_DW):
`SELECT luminaria_key, tiempo_key, hora_key, CAST(1 AS INT) AS existe_grano FROM dbo.fact_operacion_luminaria`.
Se une por `luminaria_key`, `tiempo_key` y `hora_key`. *Redirect rows to no match output*.
- **Match** → **DC_MotivoGrano**: *Replace* `motivo_validacion` = `(DT_WSTR,40)"DUPLICADO"` (otra medición ya ocupa ese intervalo).
- **No Match** → **RC_Insertadas** (`User::FilasInsertadas`) → destino.

Además el índice único `UX_fop_grano` impide los duplicados en la base aunque alguien se salte el paquete.

### 5.6 Carga

**OLE_Destino_Hecho** (OLE DB Destination, CM_DW): *Table or view – fast load*,
tabla `dbo.fact_operacion_luminaria`, *Check constraints* activado, *Rows per batch* 50000,
*Maximum insert commit size* 100000. Mapeo de columnas:

| Columna del flujo | Columna destino |
|---|---|
| medicion_id | medicion_id |
| tiempo_key, hora_key | tiempo_key, hora_key |
| luminaria_key, ubicacion_key | luminaria_key, ubicacion_key |
| sensor_luz_key, sensor_presencia_key | sensor_luz_key, sensor_presencia_key |
| estado_key, origen_key, calidad_key | estado_key, origen_key, calidad_key |
| es_noche, encendida, en_falla, es_anomala | es_noche, encendida, en_falla, es_anomala |
| lux_limpio | nivel_luz_lux |
| detecciones_limpias | detecciones |
| brillo_pct | brillo_pct |
| tension_limpia | tension_v |
| corriente_limpia | corriente_a |
| potencia_limpia | potencia_w |
| energia_limpia | energia_wh |
| energia_referencia_wh, ahorro_wh | energia_referencia_wh, ahorro_wh |
| temperatura_limpia | temperatura_c |
| ejecucion_id | ejecucion_id |
| *(Ignore)* | fact_id (identidad), fecha_carga (valor por defecto) |

### 5.7 Rechazos

**UNION_Rechazos** (Union All) recibe `CS_Validacion.Rechazadas`, `DC_MotivoClave` y `DC_MotivoGrano`.
Deje solo las columnas `medicion_id`, `luminaria_id`, `fecha_hora`, `brillo_pct` y `motivo_validacion`.

**DC_Detalle** (Derived Column):

| Columna | Tipo | Expresión |
|---|---|---|
| `detalle` | DT_WSTR (400) | `"luminaria_id=" + (DT_WSTR,6)luminaria_id + "; fecha=" + (DT_WSTR,30)fecha_hora + "; brillo=" + (ISNULL(brillo_pct) ? "NULL" : (DT_WSTR,12)brillo_pct)` |
| `ejecucion_id` | DT_I4 | `@[User::EjecucionId]` |

**RC_Rechazadas** (Row Count → `User::FilasRechazadas`) → **OLE_Destino_Rechazos** (OLE DB Destination, fast load,
`dbo.etl_rechazo`): `ejecucion_id` → ejecucion_id, `medicion_id` → medicion_id,
`motivo_validacion` → motivo, `detalle` → detalle (rechazo_id y fecha_rechazo se ignoran).

## 6. Ejecución y evidencias

1. Antes de la primera carga, el DW debe tener las dimensiones fijas (script 05). Si ya se cargó con T-SQL y quiere repetir con SSIS: `EXEC NeoGridDW.dbo.sp_etl_reiniciar;`.
2. Ejecute el paquete (F5). Las cajas verdes y los contadores de filas en las flechas del flujo de datos son la evidencia visual. Haga capturas.
3. En SSMS:

```sql
USE NeoGridDW;
SELECT TOP (5) * FROM dbo.etl_ejecucion ORDER BY ejecucion_id DESC;      -- herramienta = SSIS
SELECT * FROM dbo.etl_paso WHERE ejecucion_id = (SELECT MAX(ejecucion_id) FROM dbo.etl_ejecucion) ORDER BY paso_id;
SELECT motivo, COUNT(*) FROM dbo.etl_rechazo GROUP BY motivo;
SELECT * FROM dbo.etl_control;
```

4. **Segunda ejecución** (prueba de idempotencia): ejecute otra vez el paquete. Debe leer 0 filas e insertar 0, porque la marca de agua ya avanzó.
5. **Prueba de rechazos**: script `09_prueba_rechazos_etl.sql` (PARTE 1 → paquete → PARTE 3). Se esperan 3 insertadas y 9 rechazadas: DUPLICADO 2, FECHA_INVALIDA 2, BRILLO_FUERA_DE_RANGO 2 y VALOR_IMPOSIBLE 3.
6. **Validación completa**: `08_validacion.sql`.

## 7. Ejecución por línea de comandos (opcional)

Si el componente *Integration Services* de SQL Server está instalado:

```bat
dtexec /File "C:\neogrid\ssis\NeoGrid_ETL\ETL_NeoGrid.dtsx" /Reporting E
```

Sin el Agente SQL se puede programar con el Programador de tareas de Windows. También existe la ruta
T-SQL, que es la que usa el puente de la maqueta: `EXEC NeoGridDW.dbo.sp_etl_ejecutar_tsql;`.

## 8. Errores frecuentes

| Síntoma | Causa y solución |
|---|---|
| *The certificate chain was issued by an authority that is not trusted* | Active *Trust server certificate* en la conexión (MSOLEDBSQL 19 cifra por defecto). |
| Lookup: *The data types of the join columns do not match* | Revise que la unión sea SMALLINT ↔ SMALLINT, etc. No convierta las claves en el origen. |
| `SQL_IniciarEjecucion` no asigna variables | ResultSet = *Single row* y en *Result Set* use los nombres exactos `ejecucion_id`, `watermark_min`, `watermark_max`. |
| Error de violación de `UX_fop_grano` | Se ejecutó el destino sin `LKP_Grano`. Vuelva a conectar el Lookup. La ejecución queda FALLIDA y no avanza la marca de agua. |
| La ejecución quedó `EN_CURSO` | Se detuvo el paquete a la mitad. La siguiente ejecución la marca como FALLIDA automáticamente. |
