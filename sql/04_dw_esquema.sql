/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   04_dw_esquema.sql
   Crea la base de datos analítica NeoGridDW (modelo multidimensional).
   Esquema de constelación: una estrella principal (operación de
   luminarias cada 15 min) + hechos agregados y hechos de fallas y
   mantenimiento que comparten las mismas dimensiones conformadas.

   ATENCIÓN: si NeoGridDW ya existe, este script la BORRA y la crea de nuevo.
   Requiere: NeoGridRelacional creada (01 a 03).
   ===================================================================== */
USE master;
GO
IF DB_ID(N'NeoGridDW') IS NOT NULL
BEGIN
    ALTER DATABASE NeoGridDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE NeoGridDW;
END
GO
CREATE DATABASE NeoGridDW;
GO
ALTER DATABASE NeoGridDW SET RECOVERY SIMPLE;
GO
-- Lecturas sin bloqueos: el tablero lee la última versión confirmada mientras el ETL carga datos.
ALTER DATABASE NeoGridDW SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
ALTER DATABASE NeoGridDW MODIFY FILE (NAME = N'NeoGridDW', SIZE = 512MB, FILEGROWTH = 256MB);
GO
ALTER DATABASE NeoGridDW MODIFY FILE (NAME = N'NeoGridDW_log', SIZE = 256MB, FILEGROWTH = 256MB);
GO
USE NeoGridDW;
GO

/* ---------------------------------------------------------------------
   0. Sinónimos hacia el modelo relacional (origen del ETL en T-SQL)
   --------------------------------------------------------------------- */
CREATE SCHEMA src;
GO
CREATE SYNONYM src.zona               FOR NeoGridRelacional.dbo.zona;
CREATE SYNONYM src.ubicacion          FOR NeoGridRelacional.dbo.ubicacion;
CREATE SYNONYM src.modelo_luminaria   FOR NeoGridRelacional.dbo.modelo_luminaria;
CREATE SYNONYM src.luminaria          FOR NeoGridRelacional.dbo.luminaria;
CREATE SYNONYM src.tipo_sensor        FOR NeoGridRelacional.dbo.tipo_sensor;
CREATE SYNONYM src.sensor             FOR NeoGridRelacional.dbo.sensor;
CREATE SYNONYM src.estado_operativo   FOR NeoGridRelacional.dbo.estado_operativo;
CREATE SYNONYM src.origen_dato        FOR NeoGridRelacional.dbo.origen_dato;
CREATE SYNONYM src.tipo_falla         FOR NeoGridRelacional.dbo.tipo_falla;
CREATE SYNONYM src.falla              FOR NeoGridRelacional.dbo.falla;
CREATE SYNONYM src.tecnico            FOR NeoGridRelacional.dbo.tecnico;
CREATE SYNONYM src.tipo_mantenimiento FOR NeoGridRelacional.dbo.tipo_mantenimiento;
CREATE SYNONYM src.mantenimiento      FOR NeoGridRelacional.dbo.mantenimiento;
CREATE SYNONYM src.medicion           FOR NeoGridRelacional.dbo.medicion;
CREATE SYNONYM src.fn_etl_extraccion  FOR NeoGridRelacional.dbo.fn_etl_extraccion;
GO

/* ---------------------------------------------------------------------
   1. Tablas de control del ETL
   --------------------------------------------------------------------- */
CREATE TABLE dbo.etl_ejecucion (
    ejecucion_id              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_ejecucion PRIMARY KEY,
    herramienta               VARCHAR(10)     NOT NULL CONSTRAINT CK_etl_herramienta CHECK (herramienta IN ('SSIS', 'TSQL')),
    paquete                   NVARCHAR(100)   NOT NULL,
    inicio                    DATETIME2(0)    NOT NULL,
    fin                       DATETIME2(0)    NULL,
    estado                    VARCHAR(20)     NOT NULL CONSTRAINT CK_etl_estado CHECK (estado IN ('EN_CURSO', 'EXITOSA', 'CON_RECHAZOS', 'FALLIDA')),
    watermark_inicial         BIGINT          NOT NULL,
    watermark_final           BIGINT          NOT NULL,
    filas_leidas              INT             NOT NULL CONSTRAINT DF_etl_leidas DEFAULT (0),
    filas_insertadas          INT             NOT NULL CONSTRAINT DF_etl_insertadas DEFAULT (0),
    filas_rechazadas          INT             NOT NULL CONSTRAINT DF_etl_rechazadas DEFAULT (0),
    filas_omitidas            INT             NOT NULL CONSTRAINT DF_etl_omitidas DEFAULT (0),
    filas_imputadas           INT             NOT NULL CONSTRAINT DF_etl_imputadas DEFAULT (0),
    filas_anomalas            INT             NOT NULL CONSTRAINT DF_etl_anomalas DEFAULT (0),
    dimensiones_actualizadas  INT             NOT NULL CONSTRAINT DF_etl_dimensiones DEFAULT (0),
    mensaje                   NVARCHAR(4000)  NULL
);

CREATE TABLE dbo.etl_paso (
    paso_id        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_paso PRIMARY KEY,
    ejecucion_id   INT             NOT NULL CONSTRAINT FK_etl_paso_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
    paso           NVARCHAR(60)    NOT NULL,
    inicio         DATETIME2(0)    NOT NULL,
    fin            DATETIME2(0)    NOT NULL,
    filas          INT             NULL,
    estado         VARCHAR(12)     NOT NULL CONSTRAINT CK_etl_paso_estado CHECK (estado IN ('OK', 'ERROR')),
    mensaje        NVARCHAR(2000)  NULL
);
CREATE INDEX IX_etl_paso_ejecucion ON dbo.etl_paso (ejecucion_id);

CREATE TABLE dbo.etl_rechazo (
    rechazo_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_rechazo PRIMARY KEY,
    ejecucion_id    INT            NOT NULL CONSTRAINT FK_etl_rechazo_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
    medicion_id     BIGINT         NOT NULL,
    motivo          NVARCHAR(40)   NOT NULL,
    detalle         NVARCHAR(400)  NULL,
    fecha_rechazo   DATETIME2(0)   NOT NULL CONSTRAINT DF_etl_rechazo_fecha DEFAULT (SYSDATETIME())
);
CREATE INDEX IX_etl_rechazo_ejecucion ON dbo.etl_rechazo (ejecucion_id) INCLUDE (motivo);
CREATE INDEX IX_etl_rechazo_medicion ON dbo.etl_rechazo (medicion_id);

CREATE TABLE dbo.etl_control (
    proceso              VARCHAR(40)    NOT NULL CONSTRAINT PK_etl_control PRIMARY KEY,
    ultimo_medicion_id   BIGINT         NOT NULL,
    ultima_ejecucion_id  INT            NULL,
    actualizado          DATETIME2(0)   NULL
);
INSERT INTO dbo.etl_control (proceso, ultimo_medicion_id) VALUES ('FACT_OPERACION', 0);

/* ---------------------------------------------------------------------
   2. Dimensiones
   --------------------------------------------------------------------- */
CREATE TABLE dbo.dim_tiempo (
    tiempo_key      INT           NOT NULL CONSTRAINT PK_dim_tiempo PRIMARY KEY,   -- aaaammdd; 0 = desconocido
    fecha           DATE          NOT NULL,
    anio            SMALLINT      NOT NULL,
    semestre        TINYINT       NOT NULL,
    trimestre       TINYINT       NOT NULL,
    mes             TINYINT       NOT NULL,
    nombre_mes      NVARCHAR(12)  NOT NULL,
    anio_mes        CHAR(7)       NOT NULL,
    semana_anio     TINYINT       NOT NULL,
    dia_mes         TINYINT       NOT NULL,
    dia_semana      TINYINT       NOT NULL,                                        -- 1 = lunes … 7 = domingo
    nombre_dia      NVARCHAR(12)  NOT NULL,
    es_fin_semana   TINYINT       NOT NULL,
    es_festivo      TINYINT       NOT NULL,
    temporada       NVARCHAR(10)  NOT NULL
);

CREATE TABLE dbo.dim_hora (
    hora_key              SMALLINT      NOT NULL CONSTRAINT PK_dim_hora PRIMARY KEY,  -- hhmm en pasos de 15 min
    hora                  TINYINT       NOT NULL,
    minuto                TINYINT       NOT NULL,
    etiqueta              CHAR(5)       NOT NULL,
    franja                NVARCHAR(12)  NOT NULL,
    es_horario_nocturno   TINYINT       NOT NULL
);

CREATE TABLE dbo.dim_luminaria (
    luminaria_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_luminaria PRIMARY KEY,
    luminaria_id         SMALLINT       NOT NULL CONSTRAINT UQ_dim_luminaria_id UNIQUE,
    codigo               VARCHAR(10)    NOT NULL,
    modelo_codigo        VARCHAR(12)    NOT NULL,
    modelo_descripcion   NVARCHAR(100)  NOT NULL,
    tecnologia           VARCHAR(10)    NOT NULL,
    potencia_nominal_w   DECIMAL(6,2)   NOT NULL,
    flujo_lm             INT            NOT NULL,
    vida_util_h          INT            NOT NULL,
    es_fisica            TINYINT        NOT NULL,
    tablero              VARCHAR(5)     NULL,
    posicion_cm          SMALLINT       NULL,
    fecha_instalacion    DATE           NOT NULL,
    activa               TINYINT        NOT NULL,
    fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_luminaria_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion  DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_ubicacion (
    ubicacion_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_ubicacion PRIMARY KEY,
    ubicacion_id         SMALLINT       NOT NULL CONSTRAINT UQ_dim_ubicacion_id UNIQUE,
    codigo               VARCHAR(10)    NOT NULL,
    nombre               NVARCHAR(80)   NOT NULL,
    tipo_via             VARCHAR(15)    NOT NULL,
    longitud_m           DECIMAL(6,1)   NOT NULL,
    zona_id              TINYINT        NOT NULL,
    zona_codigo          CHAR(3)        NOT NULL,
    zona_nombre          NVARCHAR(60)   NOT NULL,
    tipo_zona            VARCHAR(15)    NOT NULL,
    es_fisica            TINYINT        NOT NULL,
    fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_ubicacion_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion  DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_sensor (
    sensor_key           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_sensor PRIMARY KEY,
    sensor_id            SMALLINT       NOT NULL CONSTRAINT UQ_dim_sensor_id UNIQUE,     -- 0 = sin sensor
    codigo               VARCHAR(12)    NOT NULL,
    tipo_codigo          VARCHAR(12)    NOT NULL,
    tipo_nombre          NVARCHAR(60)   NOT NULL,
    magnitud             NVARCHAR(40)   NOT NULL,
    unidad               NVARCHAR(15)   NOT NULL,
    es_fisico            TINYINT        NOT NULL,
    pin_gpio             VARCHAR(10)    NULL,
    modelo               NVARCHAR(40)   NOT NULL,
    ubicacion_codigo     VARCHAR(10)    NOT NULL,
    zona_codigo          CHAR(3)        NOT NULL,
    activo               TINYINT        NOT NULL,
    fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_sensor_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion  DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_estado_operativo (
    estado_key             INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_estado_operativo PRIMARY KEY,
    estado_id              TINYINT        NOT NULL CONSTRAINT UQ_dim_estado_id UNIQUE,
    codigo                 VARCHAR(15)    NOT NULL,
    nombre                 NVARCHAR(60)   NOT NULL,
    categoria              VARCHAR(20)    NOT NULL,
    brillo_referencia_pct  TINYINT        NOT NULL,
    fecha_carga            DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_estado_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion    DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_origen (
    origen_key           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_origen PRIMARY KEY,
    origen_id            TINYINT        NOT NULL CONSTRAINT UQ_dim_origen_id UNIQUE,
    codigo               VARCHAR(12)    NOT NULL,
    nombre               NVARCHAR(40)   NOT NULL,
    descripcion          NVARCHAR(200)  NULL,
    fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_origen_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion  DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_calidad_dato (
    calidad_key    TINYINT        NOT NULL CONSTRAINT PK_dim_calidad_dato PRIMARY KEY,
    codigo         VARCHAR(25)    NOT NULL,
    descripcion    NVARCHAR(150)  NOT NULL,
    fue_imputado   TINYINT        NOT NULL,
    es_anomalo     TINYINT        NOT NULL
);

CREATE TABLE dbo.dim_tipo_falla (
    tipo_falla_key         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_tipo_falla PRIMARY KEY,
    tipo_falla_id          TINYINT        NOT NULL CONSTRAINT UQ_dim_tipo_falla_id UNIQUE,
    codigo                 VARCHAR(15)    NOT NULL,
    nombre                 NVARCHAR(60)   NOT NULL,
    severidad              VARCHAR(5)     NOT NULL,
    deja_fuera_servicio    TINYINT        NOT NULL,
    fecha_carga            DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_tipo_falla_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion    DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_tipo_mantenimiento (
    tipo_mantenimiento_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_tipo_mantenimiento PRIMARY KEY,
    tipo_mantenimiento_id   TINYINT        NOT NULL CONSTRAINT UQ_dim_tipo_mant_id UNIQUE,
    codigo                  VARCHAR(25)    NOT NULL,
    nombre                  NVARCHAR(60)   NOT NULL,
    es_correctivo           TINYINT        NOT NULL,
    duracion_estimada_min   SMALLINT       NOT NULL,
    fecha_carga             DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_tipo_mant_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion     DATETIME2(0)   NULL
);

CREATE TABLE dbo.dim_tecnico (
    tecnico_key          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_tecnico PRIMARY KEY,
    tecnico_id           TINYINT        NOT NULL CONSTRAINT UQ_dim_tecnico_id UNIQUE,    -- 0 = sin asignar
    codigo               VARCHAR(8)     NOT NULL,
    nombre               NVARCHAR(60)   NOT NULL,
    especialidad         NVARCHAR(40)   NOT NULL,
    activo               TINYINT        NOT NULL,
    fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_tecnico_carga DEFAULT (SYSDATETIME()),
    fecha_actualizacion  DATETIME2(0)   NULL
);

/* ---------------------------------------------------------------------
   3. Hechos
   --------------------------------------------------------------------- */
/* Grano: una luminaria en un intervalo de 15 minutos */
CREATE TABLE dbo.fact_operacion_luminaria (
    fact_id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_operacion PRIMARY KEY,
    medicion_id             BIGINT          NOT NULL,                       -- dimensión degenerada (linaje)
    tiempo_key              INT             NOT NULL CONSTRAINT FK_fop_tiempo REFERENCES dbo.dim_tiempo (tiempo_key),
    hora_key                SMALLINT        NOT NULL CONSTRAINT FK_fop_hora REFERENCES dbo.dim_hora (hora_key),
    luminaria_key           INT             NOT NULL CONSTRAINT FK_fop_luminaria REFERENCES dbo.dim_luminaria (luminaria_key),
    ubicacion_key           INT             NOT NULL CONSTRAINT FK_fop_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
    sensor_luz_key          INT             NOT NULL CONSTRAINT FK_fop_sensor_luz REFERENCES dbo.dim_sensor (sensor_key),
    sensor_presencia_key    INT             NOT NULL CONSTRAINT FK_fop_sensor_presencia REFERENCES dbo.dim_sensor (sensor_key),
    estado_key              INT             NOT NULL CONSTRAINT FK_fop_estado REFERENCES dbo.dim_estado_operativo (estado_key),
    origen_key              INT             NOT NULL CONSTRAINT FK_fop_origen REFERENCES dbo.dim_origen (origen_key),
    calidad_key             TINYINT         NOT NULL CONSTRAINT FK_fop_calidad REFERENCES dbo.dim_calidad_dato (calidad_key),
    es_noche                TINYINT         NOT NULL,
    encendida               TINYINT         NOT NULL,
    en_falla                TINYINT         NOT NULL,
    es_anomala              TINYINT         NOT NULL,
    nivel_luz_lux           DECIMAL(9,1)    NOT NULL,
    detecciones             SMALLINT        NOT NULL,
    brillo_pct              DECIMAL(5,1)    NOT NULL,
    tension_v               DECIMAL(6,2)    NOT NULL,
    corriente_a             DECIMAL(7,3)    NOT NULL,
    potencia_w              DECIMAL(8,2)    NOT NULL,
    energia_wh              DECIMAL(10,3)   NOT NULL,
    energia_referencia_wh   DECIMAL(10,3)   NOT NULL,
    ahorro_wh               DECIMAL(10,3)   NOT NULL,
    temperatura_c           DECIMAL(5,1)    NOT NULL,
    ejecucion_id            INT             NOT NULL CONSTRAINT FK_fop_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
    fecha_carga             DATETIME2(0)    NOT NULL CONSTRAINT DF_fop_fecha_carga DEFAULT (SYSDATETIME())
);
CREATE UNIQUE INDEX UX_fop_medicion ON dbo.fact_operacion_luminaria (medicion_id);
CREATE UNIQUE INDEX UX_fop_grano ON dbo.fact_operacion_luminaria (luminaria_key, tiempo_key, hora_key);
CREATE INDEX IX_fop_tiempo ON dbo.fact_operacion_luminaria (tiempo_key, hora_key);
CREATE INDEX IX_fop_ejecucion ON dbo.fact_operacion_luminaria (ejecucion_id);
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_fop ON dbo.fact_operacion_luminaria
    (tiempo_key, hora_key, luminaria_key, ubicacion_key, estado_key, origen_key, calidad_key,
     es_noche, encendida, en_falla, es_anomala, nivel_luz_lux, detecciones, brillo_pct,
     potencia_w, energia_wh, energia_referencia_wh, ahorro_wh, temperatura_c);

/* Hecho agregado: luminaria por día (consumo y disponibilidad) */
CREATE TABLE dbo.fact_consumo_diario (
    tiempo_key               INT            NOT NULL CONSTRAINT FK_fcd_tiempo REFERENCES dbo.dim_tiempo (tiempo_key),
    luminaria_key            INT            NOT NULL CONSTRAINT FK_fcd_luminaria REFERENCES dbo.dim_luminaria (luminaria_key),
    ubicacion_key            INT            NOT NULL CONSTRAINT FK_fcd_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
    origen_key               INT            NOT NULL CONSTRAINT FK_fcd_origen REFERENCES dbo.dim_origen (origen_key),
    intervalos               INT            NOT NULL,
    intervalos_encendida     INT            NOT NULL,
    intervalos_falla         INT            NOT NULL,
    intervalos_anomalos      INT            NOT NULL,
    intervalos_imputados     INT            NOT NULL,
    detecciones              INT            NOT NULL,
    horas_encendida          DECIMAL(6,2)   NOT NULL,
    brillo_promedio_noche    DECIMAL(5,1)   NOT NULL,
    energia_kwh              DECIMAL(12,4)  NOT NULL,
    energia_referencia_kwh   DECIMAL(12,4)  NOT NULL,
    ahorro_kwh               DECIMAL(12,4)  NOT NULL,
    CONSTRAINT PK_fact_consumo_diario PRIMARY KEY (tiempo_key, luminaria_key, origen_key)
);
CREATE INDEX IX_fcd_ubicacion ON dbo.fact_consumo_diario (ubicacion_key);

/* Hecho agregado: día × hora × tramo × estado (perfiles horarios del tablero) */
CREATE TABLE dbo.fact_operacion_horaria (
    tiempo_key              INT            NOT NULL CONSTRAINT FK_foh_tiempo REFERENCES dbo.dim_tiempo (tiempo_key),
    hora_key                SMALLINT       NOT NULL CONSTRAINT FK_foh_hora REFERENCES dbo.dim_hora (hora_key),
    ubicacion_key           INT            NOT NULL CONSTRAINT FK_foh_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
    estado_key              INT            NOT NULL CONSTRAINT FK_foh_estado REFERENCES dbo.dim_estado_operativo (estado_key),
    origen_key              INT            NOT NULL CONSTRAINT FK_foh_origen REFERENCES dbo.dim_origen (origen_key),
    intervalos              INT            NOT NULL,
    intervalos_encendida    INT            NOT NULL,
    detecciones             INT            NOT NULL,
    suma_brillo             DECIMAL(12,1)  NOT NULL,
    suma_lux                DECIMAL(16,1)  NOT NULL,
    energia_wh              DECIMAL(14,3)  NOT NULL,
    energia_referencia_wh   DECIMAL(14,3)  NOT NULL,
    CONSTRAINT PK_fact_operacion_horaria PRIMARY KEY (tiempo_key, hora_key, ubicacion_key, estado_key, origen_key)
);

/* Hecho de fallas: una fila por falla */
CREATE TABLE dbo.fact_falla (
    falla_id                 INT            NOT NULL CONSTRAINT PK_fact_falla PRIMARY KEY,
    tiempo_deteccion_key     INT            NOT NULL CONSTRAINT FK_ff_tiempo_det REFERENCES dbo.dim_tiempo (tiempo_key),
    hora_deteccion_key       SMALLINT       NOT NULL CONSTRAINT FK_ff_hora_det REFERENCES dbo.dim_hora (hora_key),
    tiempo_resolucion_key    INT            NOT NULL CONSTRAINT FK_ff_tiempo_res REFERENCES dbo.dim_tiempo (tiempo_key),
    luminaria_key            INT            NOT NULL CONSTRAINT FK_ff_luminaria REFERENCES dbo.dim_luminaria (luminaria_key),
    ubicacion_key            INT            NOT NULL CONSTRAINT FK_ff_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
    tipo_falla_key           INT            NOT NULL CONSTRAINT FK_ff_tipo REFERENCES dbo.dim_tipo_falla (tipo_falla_key),
    sensor_key               INT            NOT NULL CONSTRAINT FK_ff_sensor REFERENCES dbo.dim_sensor (sensor_key),
    origen_key               INT            NOT NULL CONSTRAINT FK_ff_origen REFERENCES dbo.dim_origen (origen_key),
    esta_abierta             TINYINT        NOT NULL,
    horas_hasta_deteccion    DECIMAL(8,2)   NOT NULL,
    horas_duracion           DECIMAL(9,2)   NOT NULL,
    tiene_mantenimiento      TINYINT        NOT NULL,
    costo_correctivo_cop     DECIMAL(12,2)  NULL,
    ejecucion_id             INT            NOT NULL CONSTRAINT FK_ff_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
    fecha_carga              DATETIME2(0)   NOT NULL CONSTRAINT DF_ff_fecha_carga DEFAULT (SYSDATETIME())
);

/* Hecho de mantenimiento: una fila por orden de mantenimiento */
CREATE TABLE dbo.fact_mantenimiento (
    mantenimiento_id         INT            NOT NULL CONSTRAINT PK_fact_mantenimiento PRIMARY KEY,
    tiempo_programado_key    INT            NOT NULL CONSTRAINT FK_fm_tiempo_prog REFERENCES dbo.dim_tiempo (tiempo_key),
    tiempo_ejecucion_key     INT            NOT NULL CONSTRAINT FK_fm_tiempo_ejec REFERENCES dbo.dim_tiempo (tiempo_key),
    luminaria_key            INT            NOT NULL CONSTRAINT FK_fm_luminaria REFERENCES dbo.dim_luminaria (luminaria_key),
    ubicacion_key            INT            NOT NULL CONSTRAINT FK_fm_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
    tipo_mantenimiento_key   INT            NOT NULL CONSTRAINT FK_fm_tipo REFERENCES dbo.dim_tipo_mantenimiento (tipo_mantenimiento_key),
    tecnico_key              INT            NOT NULL CONSTRAINT FK_fm_tecnico REFERENCES dbo.dim_tecnico (tecnico_key),
    origen_key               INT            NOT NULL CONSTRAINT FK_fm_origen REFERENCES dbo.dim_origen (origen_key),
    falla_id                 INT            NULL,
    estado                   VARCHAR(12)    NOT NULL,
    es_pendiente             TINYINT        NOT NULL,
    es_correctivo            TINYINT        NOT NULL,
    duracion_min             INT            NULL,
    costo_cop                DECIMAL(12,2)  NULL,
    dias_retraso             DECIMAL(7,2)   NULL,
    ejecucion_id             INT            NOT NULL CONSTRAINT FK_fm_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
    fecha_carga              DATETIME2(0)   NOT NULL CONSTRAINT DF_fm_fecha_carga DEFAULT (SYSDATETIME())
);
GO

/* ---------------------------------------------------------------------
   4. Descripciones para el explorador web
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
EXEC dbo.sp_describir_tabla N'dim_tiempo', N'Calendario 2026–2027 con mes, semana, día de la semana, festivos de Colombia y temporada.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_hora', N'Los 96 intervalos de 15 minutos del día con su franja horaria.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_luminaria', N'Luminarias con su modelo, potencia y si son físicas (maqueta) o simuladas.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_ubicacion', N'Tramos de vía desnormalizados con su zona y tipo de zona.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_sensor', N'Sensores con tipo, unidad y pin del ESP32. Se usa dos veces (sensor de luz y de presencia).', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_estado_operativo', N'Estados de funcionamiento con su categoría (apagada, encendida, fuera de servicio).', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_origen', N'Origen del dato: simulado, físico, calculado o prueba.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_calidad_dato', N'Calidad del registro tras el ETL: original, imputado, anómalo o ambos.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_tipo_falla', N'Tipos de falla con severidad.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_tipo_mantenimiento', N'Tipos de mantenimiento preventivo y correctivo.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_tecnico', N'Técnicos o equipos de mantenimiento.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'fact_operacion_luminaria', N'Hecho principal: operación de cada luminaria cada 15 minutos (energía, brillo, luz, detecciones).', N'HECHO';
EXEC dbo.sp_describir_tabla N'fact_consumo_diario', N'Hecho agregado por luminaria y día: energía, referencia sin control, ahorro y disponibilidad.', N'HECHO_AGREGADO';
EXEC dbo.sp_describir_tabla N'fact_operacion_horaria', N'Hecho agregado por día, hora, tramo y estado para perfiles horarios.', N'HECHO_AGREGADO';
EXEC dbo.sp_describir_tabla N'fact_falla', N'Hecho de fallas: tiempo de detección, duración y costo correctivo.', N'HECHO';
EXEC dbo.sp_describir_tabla N'fact_mantenimiento', N'Hecho de mantenimiento: programados, realizados, pendientes, costo y retraso.', N'HECHO';
EXEC dbo.sp_describir_tabla N'etl_ejecucion', N'Historial de ejecuciones del ETL con filas leídas, insertadas, rechazadas y estado.', N'ETL';
EXEC dbo.sp_describir_tabla N'etl_paso', N'Pasos de cada ejecución del ETL con su duración.', N'ETL';
EXEC dbo.sp_describir_tabla N'etl_rechazo', N'Filas rechazadas por el ETL con el motivo.', N'ETL';
EXEC dbo.sp_describir_tabla N'etl_control', N'Marca de agua: última medición cargada (evita duplicados en ejecuciones posteriores).', N'ETL';
GO

/* ---------------------------------------------------------------------
   5. Vistas de metadatos (iguales a las del modelo relacional)
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

PRINT N'NeoGridDW creada: 11 dimensiones, 5 tablas de hechos y 4 tablas de control del ETL.';
GO
