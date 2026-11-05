/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   01_relacional_esquema.sql
   Crea la base de datos relacional (OLTP) NeoGridRelacional:
   tablas normalizadas, claves, restricciones, índices, vistas de
   metadatos, función de extracción para el ETL y procedimiento de
   consumo diario.

   ATENCIÓN: si la base NeoGridRelacional ya existe, este script la
   BORRA y la vuelve a crear. La base NeoGridAlumbrado (la que llena
   el suscriptor de la maqueta) NO se toca.

   Ejecutar en SSMS 22 conectado a la instancia local (F5).
   ===================================================================== */
USE master;
GO
IF DB_ID(N'NeoGridRelacional') IS NOT NULL
BEGIN
    ALTER DATABASE NeoGridRelacional SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE NeoGridRelacional;
END
GO
CREATE DATABASE NeoGridRelacional;
GO
ALTER DATABASE NeoGridRelacional SET RECOVERY SIMPLE;
GO
-- Lecturas sin bloqueos: el tablero lee la última versión confirmada mientras el puente importa datos.
ALTER DATABASE NeoGridRelacional SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
ALTER DATABASE NeoGridRelacional MODIFY FILE (NAME = N'NeoGridRelacional', SIZE = 512MB, FILEGROWTH = 256MB);
GO
ALTER DATABASE NeoGridRelacional MODIFY FILE (NAME = N'NeoGridRelacional_log', SIZE = 256MB, FILEGROWTH = 256MB);
GO
USE NeoGridRelacional;
GO

/* ---------------------------------------------------------------------
   1. Catálogos y estructura física de la red de alumbrado
   --------------------------------------------------------------------- */
CREATE TABLE dbo.origen_dato (
    origen_id      TINYINT        NOT NULL CONSTRAINT PK_origen_dato PRIMARY KEY,
    codigo         VARCHAR(12)    NOT NULL CONSTRAINT UQ_origen_dato_codigo UNIQUE,
    nombre         NVARCHAR(40)   NOT NULL,
    descripcion    NVARCHAR(200)  NULL
);

CREATE TABLE dbo.zona (
    zona_id        TINYINT        NOT NULL CONSTRAINT PK_zona PRIMARY KEY,
    codigo         CHAR(3)        NOT NULL CONSTRAINT UQ_zona_codigo UNIQUE,
    nombre         NVARCHAR(60)   NOT NULL,
    tipo_zona      VARCHAR(15)    NOT NULL CONSTRAINT CK_zona_tipo CHECK (tipo_zona IN ('RESIDENCIAL', 'VIAL', 'HOSPITALARIA', 'COMERCIAL')),
    es_fisica      BIT            NOT NULL CONSTRAINT DF_zona_es_fisica DEFAULT (0),
    descripcion    NVARCHAR(200)  NULL
);

CREATE TABLE dbo.ubicacion (
    ubicacion_id   SMALLINT       NOT NULL CONSTRAINT PK_ubicacion PRIMARY KEY,
    zona_id        TINYINT        NOT NULL CONSTRAINT FK_ubicacion_zona REFERENCES dbo.zona (zona_id),
    codigo         VARCHAR(10)    NOT NULL CONSTRAINT UQ_ubicacion_codigo UNIQUE,
    nombre         NVARCHAR(80)   NOT NULL,
    tipo_via       VARCHAR(15)    NOT NULL CONSTRAINT CK_ubicacion_tipo_via CHECK (tipo_via IN ('ANDEN', 'CALZADA', 'PLAZA', 'ACCESO', 'CALLE')),
    longitud_m     DECIMAL(6,1)   NOT NULL CONSTRAINT CK_ubicacion_longitud CHECK (longitud_m > 0)
);
CREATE INDEX IX_ubicacion_zona ON dbo.ubicacion (zona_id);

CREATE TABLE dbo.modelo_luminaria (
    modelo_id            TINYINT        NOT NULL CONSTRAINT PK_modelo_luminaria PRIMARY KEY,
    codigo               VARCHAR(12)    NOT NULL CONSTRAINT UQ_modelo_luminaria_codigo UNIQUE,
    descripcion          NVARCHAR(100)  NOT NULL,
    tecnologia           VARCHAR(10)    NOT NULL CONSTRAINT DF_modelo_tecnologia DEFAULT ('LED'),
    potencia_nominal_w   DECIMAL(6,2)   NOT NULL CONSTRAINT CK_modelo_potencia CHECK (potencia_nominal_w > 0),
    flujo_lm             INT            NOT NULL CONSTRAINT CK_modelo_flujo CHECK (flujo_lm > 0),
    vida_util_h          INT            NOT NULL CONSTRAINT CK_modelo_vida CHECK (vida_util_h > 0),
    temperatura_color_k  SMALLINT       NOT NULL
);

CREATE TABLE dbo.luminaria (
    luminaria_id       SMALLINT      NOT NULL CONSTRAINT PK_luminaria PRIMARY KEY,
    codigo             VARCHAR(10)   NOT NULL CONSTRAINT UQ_luminaria_codigo UNIQUE,
    ubicacion_id       SMALLINT      NOT NULL CONSTRAINT FK_luminaria_ubicacion REFERENCES dbo.ubicacion (ubicacion_id),
    modelo_id          TINYINT       NOT NULL CONSTRAINT FK_luminaria_modelo REFERENCES dbo.modelo_luminaria (modelo_id),
    es_fisica          BIT           NOT NULL CONSTRAINT DF_luminaria_es_fisica DEFAULT (0),
    tablero            VARCHAR(5)    NULL CONSTRAINT CK_luminaria_tablero CHECK (tablero IN ('OESTE', 'ESTE')),
    posicion_cm        SMALLINT      NULL CONSTRAINT CK_luminaria_posicion CHECK (posicion_cm BETWEEN 0 AND 100),
    fecha_instalacion  DATE          NOT NULL,
    activa             BIT           NOT NULL CONSTRAINT DF_luminaria_activa DEFAULT (1),
    CONSTRAINT CK_luminaria_fisica CHECK ((es_fisica = 1 AND tablero IS NOT NULL) OR (es_fisica = 0 AND tablero IS NULL))
);
CREATE INDEX IX_luminaria_ubicacion ON dbo.luminaria (ubicacion_id);
CREATE INDEX IX_luminaria_modelo ON dbo.luminaria (modelo_id);

CREATE TABLE dbo.tipo_sensor (
    tipo_sensor_id   TINYINT        NOT NULL CONSTRAINT PK_tipo_sensor PRIMARY KEY,
    codigo           VARCHAR(12)    NOT NULL CONSTRAINT UQ_tipo_sensor_codigo UNIQUE,
    nombre           NVARCHAR(60)   NOT NULL,
    magnitud         NVARCHAR(40)   NOT NULL,
    unidad           NVARCHAR(15)   NOT NULL,
    rango_min        DECIMAL(10,2)  NOT NULL,
    rango_max        DECIMAL(10,2)  NOT NULL,
    CONSTRAINT CK_tipo_sensor_rango CHECK (rango_max > rango_min)
);

CREATE TABLE dbo.vivienda (
    vivienda_id    SMALLINT      NOT NULL CONSTRAINT PK_vivienda PRIMARY KEY,
    codigo         VARCHAR(10)   NOT NULL CONSTRAINT UQ_vivienda_codigo UNIQUE,
    ubicacion_id   SMALLINT      NOT NULL CONSTRAINT FK_vivienda_ubicacion REFERENCES dbo.ubicacion (ubicacion_id),
    numero_luces   TINYINT       NOT NULL CONSTRAINT CK_vivienda_luces CHECK (numero_luces BETWEEN 1 AND 6),
    es_fisica      BIT           NOT NULL CONSTRAINT DF_vivienda_es_fisica DEFAULT (0)
);
CREATE INDEX IX_vivienda_ubicacion ON dbo.vivienda (ubicacion_id);

CREATE TABLE dbo.sensor (
    sensor_id          SMALLINT      NOT NULL CONSTRAINT PK_sensor PRIMARY KEY,
    codigo             VARCHAR(12)   NOT NULL CONSTRAINT UQ_sensor_codigo UNIQUE,
    tipo_sensor_id     TINYINT       NOT NULL CONSTRAINT FK_sensor_tipo REFERENCES dbo.tipo_sensor (tipo_sensor_id),
    ubicacion_id       SMALLINT      NOT NULL CONSTRAINT FK_sensor_ubicacion REFERENCES dbo.ubicacion (ubicacion_id),
    vivienda_id        SMALLINT      NULL CONSTRAINT FK_sensor_vivienda REFERENCES dbo.vivienda (vivienda_id),
    es_fisico          BIT           NOT NULL CONSTRAINT DF_sensor_es_fisico DEFAULT (0),
    pin_gpio           VARCHAR(10)   NULL,
    modelo             NVARCHAR(40)  NOT NULL,
    fecha_instalacion  DATE          NOT NULL,
    activo             BIT           NOT NULL CONSTRAINT DF_sensor_activo DEFAULT (1)
);
CREATE INDEX IX_sensor_tipo ON dbo.sensor (tipo_sensor_id);
CREATE INDEX IX_sensor_ubicacion ON dbo.sensor (ubicacion_id);

CREATE TABLE dbo.estado_operativo (
    estado_id              TINYINT       NOT NULL CONSTRAINT PK_estado_operativo PRIMARY KEY,
    codigo                 VARCHAR(15)   NOT NULL CONSTRAINT UQ_estado_operativo_codigo UNIQUE,
    nombre                 NVARCHAR(60)  NOT NULL,
    categoria              VARCHAR(20)   NOT NULL CONSTRAINT CK_estado_categoria CHECK (categoria IN ('APAGADA', 'ENCENDIDA', 'FUERA_DE_SERVICIO')),
    brillo_referencia_pct  TINYINT       NOT NULL CONSTRAINT CK_estado_brillo CHECK (brillo_referencia_pct BETWEEN 0 AND 100)
);

CREATE TABLE dbo.tipo_evento (
    tipo_evento_id   TINYINT       NOT NULL CONSTRAINT PK_tipo_evento PRIMARY KEY,
    codigo           VARCHAR(25)   NOT NULL CONSTRAINT UQ_tipo_evento_codigo UNIQUE,
    nombre           NVARCHAR(60)  NOT NULL,
    categoria        VARCHAR(15)   NOT NULL CONSTRAINT CK_tipo_evento_categoria CHECK (categoria IN ('OPERACION', 'SENSOR', 'FALLA', 'MANTENIMIENTO', 'COMUNICACION'))
);

CREATE TABLE dbo.tipo_falla (
    tipo_falla_id         TINYINT        NOT NULL CONSTRAINT PK_tipo_falla PRIMARY KEY,
    codigo                VARCHAR(15)    NOT NULL CONSTRAINT UQ_tipo_falla_codigo UNIQUE,
    nombre                NVARCHAR(60)   NOT NULL,
    severidad             VARCHAR(5)     NOT NULL CONSTRAINT CK_tipo_falla_severidad CHECK (severidad IN ('BAJA', 'MEDIA', 'ALTA')),
    deja_fuera_servicio   BIT            NOT NULL,
    descripcion           NVARCHAR(200)  NULL
);

CREATE TABLE dbo.tecnico (
    tecnico_id     TINYINT       NOT NULL CONSTRAINT PK_tecnico PRIMARY KEY,
    codigo         VARCHAR(8)    NOT NULL CONSTRAINT UQ_tecnico_codigo UNIQUE,
    nombre         NVARCHAR(60)  NOT NULL,
    especialidad   NVARCHAR(40)  NOT NULL,
    activo         BIT           NOT NULL CONSTRAINT DF_tecnico_activo DEFAULT (1)
);

CREATE TABLE dbo.tipo_mantenimiento (
    tipo_mantenimiento_id   TINYINT       NOT NULL CONSTRAINT PK_tipo_mantenimiento PRIMARY KEY,
    codigo                  VARCHAR(25)   NOT NULL CONSTRAINT UQ_tipo_mantenimiento_codigo UNIQUE,
    nombre                  NVARCHAR(60)  NOT NULL,
    es_correctivo           BIT           NOT NULL,
    duracion_estimada_min   SMALLINT      NOT NULL CONSTRAINT CK_tipo_mant_duracion CHECK (duracion_estimada_min > 0)
);

/* ---------------------------------------------------------------------
   2. Registros operativos
   --------------------------------------------------------------------- */
CREATE TABLE dbo.condicion_ambiental (
    condicion_id       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_condicion_ambiental PRIMARY KEY,
    zona_id            TINYINT        NOT NULL CONSTRAINT FK_condicion_zona REFERENCES dbo.zona (zona_id),
    fecha_hora         DATETIME2(0)   NOT NULL,
    temperatura_c      DECIMAL(4,1)   NOT NULL,
    humedad_pct        DECIMAL(4,1)   NOT NULL CONSTRAINT CK_condicion_humedad CHECK (humedad_pct BETWEEN 0 AND 100),
    nubosidad_pct      DECIMAL(4,1)   NOT NULL CONSTRAINT CK_condicion_nubosidad CHECK (nubosidad_pct BETWEEN 0 AND 100),
    precipitacion_mm   DECIMAL(5,2)   NOT NULL CONSTRAINT CK_condicion_precipitacion CHECK (precipitacion_mm >= 0),
    luz_natural_lux    DECIMAL(9,1)   NOT NULL CONSTRAINT CK_condicion_lux CHECK (luz_natural_lux >= 0),
    origen_id          TINYINT        NOT NULL CONSTRAINT FK_condicion_origen REFERENCES dbo.origen_dato (origen_id),
    CONSTRAINT UQ_condicion_zona_fecha UNIQUE (zona_id, fecha_hora)
);

CREATE TABLE dbo.falla (
    falla_id           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_falla PRIMARY KEY,
    luminaria_id       SMALLINT       NOT NULL CONSTRAINT FK_falla_luminaria REFERENCES dbo.luminaria (luminaria_id),
    sensor_id          SMALLINT       NULL CONSTRAINT FK_falla_sensor REFERENCES dbo.sensor (sensor_id),
    tipo_falla_id      TINYINT        NOT NULL CONSTRAINT FK_falla_tipo REFERENCES dbo.tipo_falla (tipo_falla_id),
    origen_id          TINYINT        NOT NULL CONSTRAINT FK_falla_origen REFERENCES dbo.origen_dato (origen_id),
    fecha_inicio       DATETIME2(0)   NOT NULL,
    fecha_deteccion    DATETIME2(0)   NOT NULL,
    fecha_resolucion   DATETIME2(0)   NULL,
    estado             VARCHAR(12)    NOT NULL CONSTRAINT CK_falla_estado CHECK (estado IN ('ABIERTA', 'EN_ATENCION', 'RESUELTA')),
    descripcion        NVARCHAR(200)  NULL,
    CONSTRAINT CK_falla_deteccion CHECK (fecha_deteccion >= fecha_inicio),
    CONSTRAINT CK_falla_resolucion CHECK (fecha_resolucion IS NULL OR fecha_resolucion >= fecha_deteccion),
    CONSTRAINT CK_falla_estado_fecha CHECK ((estado = 'RESUELTA' AND fecha_resolucion IS NOT NULL) OR (estado <> 'RESUELTA' AND fecha_resolucion IS NULL))
);
CREATE INDEX IX_falla_luminaria ON dbo.falla (luminaria_id, fecha_inicio);
CREATE INDEX IX_falla_estado ON dbo.falla (estado) INCLUDE (luminaria_id, tipo_falla_id);

CREATE TABLE dbo.mantenimiento (
    mantenimiento_id        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_mantenimiento PRIMARY KEY,
    luminaria_id            SMALLINT       NOT NULL CONSTRAINT FK_mantenimiento_luminaria REFERENCES dbo.luminaria (luminaria_id),
    tipo_mantenimiento_id   TINYINT        NOT NULL CONSTRAINT FK_mantenimiento_tipo REFERENCES dbo.tipo_mantenimiento (tipo_mantenimiento_id),
    tecnico_id              TINYINT        NULL CONSTRAINT FK_mantenimiento_tecnico REFERENCES dbo.tecnico (tecnico_id),
    falla_id                INT            NULL CONSTRAINT FK_mantenimiento_falla REFERENCES dbo.falla (falla_id),
    origen_id               TINYINT        NOT NULL CONSTRAINT FK_mantenimiento_origen REFERENCES dbo.origen_dato (origen_id),
    fecha_programada        DATETIME2(0)   NOT NULL,
    fecha_inicio            DATETIME2(0)   NULL,
    fecha_fin               DATETIME2(0)   NULL,
    estado                  VARCHAR(12)    NOT NULL CONSTRAINT CK_mantenimiento_estado CHECK (estado IN ('PROGRAMADO', 'EN_PROCESO', 'REALIZADO', 'CANCELADO')),
    costo_cop               DECIMAL(12,2)  NULL CONSTRAINT CK_mantenimiento_costo CHECK (costo_cop >= 0),
    observaciones           NVARCHAR(200)  NULL,
    CONSTRAINT CK_mantenimiento_fechas CHECK (fecha_fin IS NULL OR fecha_inicio IS NULL OR fecha_fin >= fecha_inicio),
    CONSTRAINT CK_mantenimiento_realizado CHECK (estado <> 'REALIZADO' OR (fecha_inicio IS NOT NULL AND fecha_fin IS NOT NULL))
);
CREATE INDEX IX_mantenimiento_luminaria ON dbo.mantenimiento (luminaria_id, fecha_programada);
CREATE INDEX IX_mantenimiento_estado ON dbo.mantenimiento (estado) INCLUDE (luminaria_id, fecha_programada);
CREATE INDEX IX_mantenimiento_falla ON dbo.mantenimiento (falla_id);

/* Tabla principal: una fila por luminaria cada 15 minutos.
   Las magnitudes medidas no llevan CHECK a propósito: son lecturas
   crudas de sensores y se validan en el ETL (se conserva la trazabilidad). */
CREATE TABLE dbo.medicion (
    medicion_id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_medicion PRIMARY KEY,
    luminaria_id          SMALLINT       NOT NULL CONSTRAINT FK_medicion_luminaria REFERENCES dbo.luminaria (luminaria_id),
    sensor_luz_id         SMALLINT       NULL CONSTRAINT FK_medicion_sensor_luz REFERENCES dbo.sensor (sensor_id),
    sensor_presencia_id   SMALLINT       NULL CONSTRAINT FK_medicion_sensor_presencia REFERENCES dbo.sensor (sensor_id),
    estado_id             TINYINT        NOT NULL CONSTRAINT FK_medicion_estado REFERENCES dbo.estado_operativo (estado_id),
    origen_id             TINYINT        NOT NULL CONSTRAINT FK_medicion_origen REFERENCES dbo.origen_dato (origen_id),
    fecha_hora            DATETIME2(0)   NOT NULL,
    es_noche              BIT            NOT NULL,
    lectura_ldr           SMALLINT       NULL,
    nivel_luz_lux         DECIMAL(9,1)   NULL,
    detecciones           SMALLINT       NULL,
    brillo_pct            DECIMAL(5,1)   NULL,
    tension_v             DECIMAL(6,2)   NULL,
    corriente_a           DECIMAL(7,3)   NULL,
    potencia_w            DECIMAL(8,2)   NULL,
    energia_wh            DECIMAL(10,3)  NULL,
    temperatura_c         DECIMAL(5,1)   NULL,
    es_anomala            BIT            NOT NULL CONSTRAINT DF_medicion_es_anomala DEFAULT (0),
    fecha_registro        DATETIME2(0)   NOT NULL CONSTRAINT DF_medicion_fecha_registro DEFAULT (SYSDATETIME())
);
CREATE INDEX IX_medicion_luminaria_fecha ON dbo.medicion (luminaria_id, fecha_hora) INCLUDE (estado_id, brillo_pct);
CREATE INDEX IX_medicion_fecha ON dbo.medicion (fecha_hora);
CREATE INDEX IX_medicion_origen ON dbo.medicion (origen_id);

CREATE TABLE dbo.evento_operativo (
    evento_id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_evento_operativo PRIMARY KEY,
    luminaria_id         SMALLINT       NULL CONSTRAINT FK_evento_luminaria REFERENCES dbo.luminaria (luminaria_id),
    ubicacion_id         SMALLINT       NOT NULL CONSTRAINT FK_evento_ubicacion REFERENCES dbo.ubicacion (ubicacion_id),
    tipo_evento_id       TINYINT        NOT NULL CONSTRAINT FK_evento_tipo REFERENCES dbo.tipo_evento (tipo_evento_id),
    origen_id            TINYINT        NOT NULL CONSTRAINT FK_evento_origen REFERENCES dbo.origen_dato (origen_id),
    fecha_hora           DATETIME2(0)   NOT NULL,
    estado_anterior_id   TINYINT        NULL CONSTRAINT FK_evento_estado_anterior REFERENCES dbo.estado_operativo (estado_id),
    estado_nuevo_id      TINYINT        NULL CONSTRAINT FK_evento_estado_nuevo REFERENCES dbo.estado_operativo (estado_id),
    brillo_anterior      DECIMAL(5,1)   NULL,
    brillo_nuevo         DECIMAL(5,1)   NULL,
    falla_id             INT            NULL CONSTRAINT FK_evento_falla REFERENCES dbo.falla (falla_id),
    mantenimiento_id     INT            NULL CONSTRAINT FK_evento_mantenimiento REFERENCES dbo.mantenimiento (mantenimiento_id),
    detalle              NVARCHAR(200)  NULL
);
CREATE INDEX IX_evento_fecha ON dbo.evento_operativo (fecha_hora);
CREATE INDEX IX_evento_luminaria ON dbo.evento_operativo (luminaria_id, fecha_hora);
CREATE INDEX IX_evento_tipo ON dbo.evento_operativo (tipo_evento_id);

CREATE TABLE dbo.registro_luces_vivienda (
    registro_id        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_registro_luces_vivienda PRIMARY KEY,
    vivienda_id        SMALLINT       NOT NULL CONSTRAINT FK_registro_luces_vivienda REFERENCES dbo.vivienda (vivienda_id),
    origen_id          TINYINT        NOT NULL CONSTRAINT FK_registro_luces_origen REFERENCES dbo.origen_dato (origen_id),
    fecha_hora         DATETIME2(0)   NOT NULL,
    luces_encendidas   TINYINT        NOT NULL,
    luces_apagadas     TINYINT        NOT NULL,
    CONSTRAINT UQ_registro_luces_vivienda_fecha UNIQUE (vivienda_id, fecha_hora)
);
CREATE INDEX IX_registro_luces_fecha ON dbo.registro_luces_vivienda (fecha_hora);

CREATE TABLE dbo.consumo_energetico (
    consumo_id               INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_consumo_energetico PRIMARY KEY,
    luminaria_id             SMALLINT       NOT NULL CONSTRAINT FK_consumo_luminaria REFERENCES dbo.luminaria (luminaria_id),
    fecha                    DATE           NOT NULL,
    origen_id                TINYINT        NOT NULL CONSTRAINT FK_consumo_origen REFERENCES dbo.origen_dato (origen_id),
    energia_kwh              DECIMAL(10,4)  NOT NULL CONSTRAINT CK_consumo_energia CHECK (energia_kwh >= 0),
    energia_referencia_kwh   DECIMAL(10,4)  NOT NULL,
    horas_encendida          DECIMAL(5,2)   NOT NULL CONSTRAINT CK_consumo_horas CHECK (horas_encendida BETWEEN 0 AND 24),
    intervalos_medidos       SMALLINT       NOT NULL,
    intervalos_imputados     SMALLINT       NOT NULL,
    fecha_calculo            DATETIME2(0)   NOT NULL CONSTRAINT DF_consumo_fecha_calculo DEFAULT (SYSDATETIME()),
    CONSTRAINT UQ_consumo_luminaria_fecha UNIQUE (luminaria_id, fecha)
);

CREATE TABLE dbo.integracion_control (
    proceso                  VARCHAR(30)    NOT NULL CONSTRAINT PK_integracion_control PRIMARY KEY,
    ultimo_id_origen         BIGINT         NOT NULL CONSTRAINT DF_integracion_ultimo_id DEFAULT (0),
    ultima_marca             DATETIME2(0)   NULL,
    ultima_ejecucion         DATETIME2(0)   NULL,
    filas_ultima_ejecucion   INT            NULL
);
GO

/* ---------------------------------------------------------------------
   3. Descripciones (propiedades extendidas) para el explorador web
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_describir_tabla
    @tabla SYSNAME,
    @descripcion NVARCHAR(400),
    @categoria NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = OBJECT_ID(N'dbo.' + @tabla);
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 1 AND major_id = @id AND minor_id = 0 AND name = N'MS_Description')
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = @descripcion, @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = @tabla;
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = @descripcion, @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = @tabla;
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 1 AND major_id = @id AND minor_id = 0 AND name = N'Categoria')
        EXEC sys.sp_updateextendedproperty @name = N'Categoria', @value = @categoria, @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = @tabla;
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'Categoria', @value = @categoria, @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = @tabla;
END
GO
EXEC dbo.sp_describir_tabla N'origen_dato', N'Origen de cada registro: simulado, físico (maqueta), calculado o de prueba del ETL.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'zona', N'Sectores de la ciudad NeoGrid. Oeste y Este son los dos tableros físicos de la maqueta.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'ubicacion', N'Tramos de vía dentro de cada zona donde se instalan luminarias y sensores.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'modelo_luminaria', N'Modelos de luminaria con su potencia nominal, flujo luminoso y vida útil.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'luminaria', N'Postes de alumbrado. 16 son físicos (8 por tablero de la maqueta) y 48 simulados.', N'MAESTRA';
EXEC dbo.sp_describir_tabla N'tipo_sensor', N'Tipos de sensor: LDR, PIR, interruptor de vivienda, medidor de energía y estación ambiental.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'vivienda', N'Casas con contador de luces. 8 son físicas (4 por tablero) y 16 simuladas.', N'MAESTRA';
EXEC dbo.sp_describir_tabla N'sensor', N'Sensores instalados, con pin del ESP32 cuando son físicos.', N'MAESTRA';
EXEC dbo.sp_describir_tabla N'estado_operativo', N'Estados de funcionamiento de una luminaria (apagada, nivel base, madrugada, presencia, ahorro, falla, mantenimiento).', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'tipo_evento', N'Tipos de evento operativo: encendido, apagado, cambio de brillo, fallas, mantenimiento y comunicación.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'tipo_falla', N'Tipos de falla con su severidad y si dejan la luminaria fuera de servicio.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'tecnico', N'Personas o equipos que ejecutan los mantenimientos.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'tipo_mantenimiento', N'Tipos de mantenimiento preventivo y correctivo con duración estimada.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'condicion_ambiental', N'Clima por zona y hora: temperatura, humedad, nubosidad, lluvia y luz natural.', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'falla', N'Fallas detectadas en luminarias y sensores, abiertas o resueltas.', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'mantenimiento', N'Mantenimientos programados, realizados o cancelados, con costo y técnico.', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'medicion', N'Tabla principal: estado y mediciones de cada luminaria cada 15 minutos (1.000.000 de filas simuladas + datos de la maqueta).', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'evento_operativo', N'Cambios de estado de las luminarias y eventos de falla, mantenimiento y comunicación.', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'registro_luces_vivienda', N'Contador de luces encendidas y apagadas de cada vivienda en el tiempo.', N'TRANSACCIONAL';
EXEC dbo.sp_describir_tabla N'consumo_energetico', N'Consumo diario por luminaria calculado a partir de las mediciones.', N'CALCULADA';
EXEC dbo.sp_describir_tabla N'integracion_control', N'Marca de agua de la importación de datos de la maqueta física.', N'CONTROL';
GO

/* ---------------------------------------------------------------------
   4. Vistas de metadatos (las usa el explorador del dashboard)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_meta_tablas
AS
SELECT
    t.name AS tabla,
    CAST(dsc.value AS NVARCHAR(400)) AS descripcion,
    CAST(cat.value AS NVARCHAR(40)) AS categoria,
    CAST((SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS BIGINT) AS filas,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS columnas
FROM sys.tables t
LEFT JOIN sys.extended_properties dsc ON dsc.class = 1 AND dsc.major_id = t.object_id AND dsc.minor_id = 0 AND dsc.name = N'MS_Description'
LEFT JOIN sys.extended_properties cat ON cat.class = 1 AND cat.major_id = t.object_id AND cat.minor_id = 0 AND cat.name = N'Categoria'
WHERE t.is_ms_shipped = 0 AND SCHEMA_NAME(t.schema_id) = N'dbo';
GO

CREATE OR ALTER VIEW dbo.vw_meta_columnas
AS
SELECT
    t.name AS tabla,
    c.column_id AS orden,
    c.name AS columna,
    ty.name AS tipo,
    CASE
        WHEN ty.name IN ('varchar', 'char', 'varbinary', 'binary') THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
        WHEN ty.name IN ('nvarchar', 'nchar') THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS VARCHAR(10)) END + ')'
        WHEN ty.name IN ('decimal', 'numeric') THEN ty.name + '(' + CAST(c.precision AS VARCHAR(5)) + ',' + CAST(c.scale AS VARCHAR(5)) + ')'
        WHEN ty.name IN ('datetime2', 'time', 'datetimeoffset') THEN ty.name + '(' + CAST(c.scale AS VARCHAR(5)) + ')'
        ELSE ty.name
    END AS tipo_completo,
    CAST(c.is_nullable AS INT) AS admite_nulos,
    CAST(c.is_identity AS INT) AS es_identidad,
    CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END AS es_pk,
    CASE WHEN fk.parent_column_id IS NOT NULL THEN 1 ELSE 0 END AS es_fk,
    OBJECT_NAME(fk.referenced_object_id) AS tabla_referenciada,
    COL_NAME(fk.referenced_object_id, fk.referenced_column_id) AS columna_referenciada
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN (
    SELECT ic.object_id, ic.column_id
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    WHERE i.is_primary_key = 1
) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
OUTER APPLY (
    SELECT TOP (1) fkc.parent_column_id, fkc.referenced_object_id, fkc.referenced_column_id
    FROM sys.foreign_key_columns fkc
    WHERE fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id
) fk
WHERE t.is_ms_shipped = 0 AND SCHEMA_NAME(t.schema_id) = N'dbo';
GO

CREATE OR ALTER VIEW dbo.vw_meta_relaciones
AS
SELECT
    f.name AS restriccion,
    OBJECT_NAME(f.parent_object_id) AS tabla_origen,
    COL_NAME(fc.parent_object_id, fc.parent_column_id) AS columna_origen,
    OBJECT_NAME(f.referenced_object_id) AS tabla_destino,
    COL_NAME(fc.referenced_object_id, fc.referenced_column_id) AS columna_destino
FROM sys.foreign_keys f
JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = f.object_id;
GO

CREATE OR ALTER VIEW dbo.vw_meta_indices
AS
SELECT
    t.name AS tabla,
    i.name AS indice,
    i.type_desc AS tipo,
    CAST(i.is_unique AS INT) AS es_unico,
    CAST(i.is_primary_key AS INT) AS es_pk,
    (SELECT STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id)
       FROM sys.index_columns ic
       JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
      WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0) AS columnas,
    (SELECT STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.index_column_id)
       FROM sys.index_columns ic
       JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
      WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1) AS columnas_incluidas
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
WHERE t.is_ms_shipped = 0 AND i.type > 0 AND SCHEMA_NAME(t.schema_id) = N'dbo';
GO

/* ---------------------------------------------------------------------
   5. Función de extracción para el ETL (la usan SSIS y el ETL en T-SQL)
   Devuelve las mediciones con id en (@desde_id, @hasta_id], con las
   claves de fecha y hora ya calculadas, los valores de referencia
   del clima para imputar nulos y el orden de duplicado por grano
   (luminaria + intervalo de 15 minutos).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_etl_extraccion (@desde_id BIGINT, @hasta_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT
    m.medicion_id,
    m.luminaria_id,
    l.ubicacion_id,
    ISNULL(m.sensor_luz_id, CAST(0 AS SMALLINT)) AS sensor_luz_id,
    ISNULL(m.sensor_presencia_id, CAST(0 AS SMALLINT)) AS sensor_presencia_id,
    m.estado_id,
    m.origen_id,
    CAST(m.fecha_hora AS DATETIME) AS fecha_hora,
    CAST(CONVERT(CHAR(8), m.fecha_hora, 112) AS INT) AS tiempo_key,
    CAST(DATEPART(HOUR, m.fecha_hora) * 100 + (DATEPART(MINUTE, m.fecha_hora) / 15) * 15 AS SMALLINT) AS hora_key,
    CAST(m.es_noche AS TINYINT) AS es_noche,
    m.nivel_luz_lux,
    m.lectura_ldr,
    m.detecciones,
    m.brillo_pct,
    m.tension_v,
    m.corriente_a,
    m.potencia_w,
    m.energia_wh,
    m.temperatura_c,
    CAST(m.es_anomala AS TINYINT) AS es_anomala,
    mo.potencia_nominal_w,
    ca.luz_natural_lux AS lux_referencia,
    ca.temperatura_c AS temperatura_ambiente,
    CAST(ROW_NUMBER() OVER (
        PARTITION BY m.luminaria_id, CONVERT(CHAR(8), m.fecha_hora, 112), DATEPART(HOUR, m.fecha_hora), DATEPART(MINUTE, m.fecha_hora) / 15
        ORDER BY m.medicion_id) AS INT) AS orden_duplicado
FROM dbo.medicion m
JOIN dbo.luminaria l ON l.luminaria_id = m.luminaria_id
JOIN dbo.ubicacion u ON u.ubicacion_id = l.ubicacion_id
JOIN dbo.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
LEFT JOIN dbo.condicion_ambiental ca
       ON ca.zona_id = u.zona_id
      AND ca.fecha_hora = DATEADD(HOUR, DATEDIFF(HOUR, CAST('20000101' AS DATETIME2(0)), m.fecha_hora), CAST('20000101' AS DATETIME2(0)))
WHERE m.medicion_id > @desde_id
  AND m.medicion_id <= @hasta_id;
GO

/* ---------------------------------------------------------------------
   6. Consumo diario por luminaria (dato CALCULADO)
   Si una medición no trae energía, se estima con la potencia nominal
   y el brillo; esos intervalos se cuentan como imputados.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_calcular_consumo_diario
    @desde DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d DATE = ISNULL(@desde, '19000101');
    DECLARE @d_ini DATETIME2(0) = CAST(@d AS DATETIME2(0));

    DELETE FROM dbo.consumo_energetico WHERE fecha >= @d;

    INSERT INTO dbo.consumo_energetico
        (luminaria_id, fecha, origen_id, energia_kwh, energia_referencia_kwh, horas_encendida, intervalos_medidos, intervalos_imputados)
    SELECT
        m.luminaria_id,
        CAST(m.fecha_hora AS DATE),
        3,
        CAST(SUM(CASE WHEN m.energia_wh IS NULL OR m.energia_wh < 0
                      THEN (mo.potencia_nominal_w * ISNULL(m.brillo_pct, 0) / 100.0 + 1.5) * 0.25
                      ELSE m.energia_wh END) / 1000.0 AS DECIMAL(10,4)),
        CAST(SUM(CASE WHEN m.es_noche = 1 THEN (mo.potencia_nominal_w + 1.5) * 0.25 ELSE 0.375 END) / 1000.0 AS DECIMAL(10,4)),
        CAST(SUM(CASE WHEN m.brillo_pct > 0 THEN 0.25 ELSE 0 END) AS DECIMAL(5,2)),
        COUNT(*),
        SUM(CASE WHEN m.energia_wh IS NULL OR m.energia_wh < 0 THEN 1 ELSE 0 END)
    FROM dbo.medicion m
    JOIN dbo.luminaria l ON l.luminaria_id = m.luminaria_id
    JOIN dbo.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
    WHERE m.fecha_hora >= @d_ini
      AND m.origen_id IN (1, 2)
    GROUP BY m.luminaria_id, CAST(m.fecha_hora AS DATE)
    OPTION (RECOMPILE);   -- plan y memoria a la medida de @desde (el puente lo llama solo con el día de hoy)
END
GO

PRINT N'NeoGridRelacional creada: 21 tablas, 4 vistas de metadatos, función de extracción y procedimiento de consumo.';
GO
