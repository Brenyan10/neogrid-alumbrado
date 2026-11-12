/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   11_dw_eventos.sql
   Agrega al data warehouse la ESTRELLA DE EVENTOS:

     fact_evento_operativo   grano: un evento operativo (encendido, apagado,
                             cambio de brillo, presencia, luz ambiente, falla,
                             mantenimiento o comunicación)
     dim_tipo_evento         tipo y categoría del evento
     dim_proceso             proceso de la operación al que pertenece el evento
     dim_usuario             usuario responsable de la acción (rol, cargo)

   Reutiliza las dimensiones conformadas dim_tiempo, dim_hora, dim_luminaria,
   dim_ubicacion, dim_estado_operativo (anterior y nuevo) y dim_origen.

   También adapta las tablas de control del ETL para contar los eventos
   (leídos, insertados, rechazados y omitidos) y registrar sus rechazos.

   Orden: 04 → 05 → 11 → 06 (06 crea los procedimientos que usan estas tablas).
   Se puede ejecutar varias veces. NO borra los hechos ya cargados.
   Requiere: 10_usuarios_procesos.sql en NeoGridRelacional.
   ===================================================================== */
USE NeoGridDW;
GO
SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   1. Sinónimos hacia el modelo relacional
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'src.evento_operativo', N'SN') IS NULL          CREATE SYNONYM src.evento_operativo          FOR NeoGridRelacional.dbo.evento_operativo;
IF OBJECT_ID(N'src.tipo_evento', N'SN') IS NULL               CREATE SYNONYM src.tipo_evento               FOR NeoGridRelacional.dbo.tipo_evento;
IF OBJECT_ID(N'src.usuario', N'SN') IS NULL                   CREATE SYNONYM src.usuario                   FOR NeoGridRelacional.dbo.usuario;
IF OBJECT_ID(N'src.vw_usuario', N'SN') IS NULL                CREATE SYNONYM src.vw_usuario                FOR NeoGridRelacional.dbo.vw_usuario;
IF OBJECT_ID(N'src.rol', N'SN') IS NULL                       CREATE SYNONYM src.rol                       FOR NeoGridRelacional.dbo.rol;
IF OBJECT_ID(N'src.proceso', N'SN') IS NULL                   CREATE SYNONYM src.proceso                   FOR NeoGridRelacional.dbo.proceso;
IF OBJECT_ID(N'src.usuario_proceso', N'SN') IS NULL           CREATE SYNONYM src.usuario_proceso           FOR NeoGridRelacional.dbo.usuario_proceso;
IF OBJECT_ID(N'src.fn_etl_extraccion_eventos', N'SN') IS NULL CREATE SYNONYM src.fn_etl_extraccion_eventos FOR NeoGridRelacional.dbo.fn_etl_extraccion_eventos;
GO

/* ---------------------------------------------------------------------
   2. Control del ETL: conteos de eventos y rechazos de eventos
   --------------------------------------------------------------------- */
IF COL_LENGTH('dbo.etl_ejecucion', 'evento_watermark_inicial') IS NULL
    ALTER TABLE dbo.etl_ejecucion ADD
        evento_watermark_inicial  BIGINT  NOT NULL CONSTRAINT DF_etl_ev_wm_ini DEFAULT (0),
        evento_watermark_final    BIGINT  NOT NULL CONSTRAINT DF_etl_ev_wm_fin DEFAULT (0),
        eventos_leidos            INT     NOT NULL CONSTRAINT DF_etl_ev_leidos DEFAULT (0),
        eventos_insertados        INT     NOT NULL CONSTRAINT DF_etl_ev_insertados DEFAULT (0),
        eventos_rechazados        INT     NOT NULL CONSTRAINT DF_etl_ev_rechazados DEFAULT (0),
        eventos_omitidos          INT     NOT NULL CONSTRAINT DF_etl_ev_omitidos DEFAULT (0);
GO

/* etl_rechazo guarda rechazos de mediciones (medicion_id) o de eventos (evento_id) */
IF COL_LENGTH('dbo.etl_rechazo', 'evento_id') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_etl_rechazo_medicion' AND object_id = OBJECT_ID(N'dbo.etl_rechazo'))
        DROP INDEX IX_etl_rechazo_medicion ON dbo.etl_rechazo;
    ALTER TABLE dbo.etl_rechazo ALTER COLUMN medicion_id BIGINT NULL;
    ALTER TABLE dbo.etl_rechazo ADD evento_id BIGINT NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_etl_rechazo_registro')
    ALTER TABLE dbo.etl_rechazo WITH CHECK ADD CONSTRAINT CK_etl_rechazo_registro
        CHECK ((medicion_id IS NOT NULL AND evento_id IS NULL) OR (medicion_id IS NULL AND evento_id IS NOT NULL));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_etl_rechazo_medicion' AND object_id = OBJECT_ID(N'dbo.etl_rechazo'))
    CREATE INDEX IX_etl_rechazo_medicion ON dbo.etl_rechazo (medicion_id);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_etl_rechazo_evento' AND object_id = OBJECT_ID(N'dbo.etl_rechazo'))
    CREATE INDEX IX_etl_rechazo_evento ON dbo.etl_rechazo (evento_id);

IF NOT EXISTS (SELECT 1 FROM dbo.etl_control WHERE proceso = 'FACT_EVENTO')
    INSERT INTO dbo.etl_control (proceso, ultimo_medicion_id) VALUES ('FACT_EVENTO', 0);   -- en esta fila la columna guarda el último evento_id
GO

/* ---------------------------------------------------------------------
   3. Dimensiones nuevas
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.dim_tipo_evento', N'U') IS NULL
    CREATE TABLE dbo.dim_tipo_evento (
        tipo_evento_key      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_tipo_evento PRIMARY KEY,
        tipo_evento_id       TINYINT        NOT NULL CONSTRAINT UQ_dim_tipo_evento_id UNIQUE,   -- 0 = desconocido
        codigo               VARCHAR(25)    NOT NULL,
        nombre               NVARCHAR(60)   NOT NULL,
        categoria            VARCHAR(15)    NOT NULL,
        fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_tipo_evento_carga DEFAULT (SYSDATETIME()),
        fecha_actualizacion  DATETIME2(0)   NULL
    );

IF OBJECT_ID(N'dbo.dim_proceso', N'U') IS NULL
    CREATE TABLE dbo.dim_proceso (
        proceso_key          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_proceso PRIMARY KEY,
        proceso_id           TINYINT        NOT NULL CONSTRAINT UQ_dim_proceso_id UNIQUE,       -- 0 = desconocido
        codigo               VARCHAR(15)    NOT NULL,
        nombre               NVARCHAR(80)   NOT NULL,
        tipo_operacion       VARCHAR(12)    NOT NULL,
        es_automatico        TINYINT        NOT NULL,
        responsable_login    VARCHAR(20)    NOT NULL,     -- desnormalizado desde usuario_proceso
        responsable_nombre   NVARCHAR(60)   NOT NULL,
        usuarios_asignados   INT            NOT NULL,
        fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_proceso_carga DEFAULT (SYSDATETIME()),
        fecha_actualizacion  DATETIME2(0)   NULL
    );

IF OBJECT_ID(N'dbo.dim_usuario', N'U') IS NULL
    CREATE TABLE dbo.dim_usuario (
        usuario_key          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_usuario PRIMARY KEY,
        usuario_id           SMALLINT       NOT NULL CONSTRAINT UQ_dim_usuario_id UNIQUE,       -- 0 = desconocido
        login                VARCHAR(20)    NOT NULL,
        nombre               NVARCHAR(60)   NOT NULL,
        rol_codigo           VARCHAR(15)    NOT NULL,
        rol_nombre           NVARCHAR(60)   NOT NULL,
        cargo                NVARCHAR(80)   NOT NULL,
        es_automatico        TINYINT        NOT NULL,
        es_tecnico           TINYINT        NOT NULL,
        tecnico_codigo       VARCHAR(8)     NULL,
        especialidad         NVARCHAR(40)   NULL,
        procesos_responsable NVARCHAR(200)  NOT NULL,     -- desnormalizado: procesos donde es RESPONSABLE
        activo               TINYINT        NOT NULL,
        fecha_carga          DATETIME2(0)   NOT NULL CONSTRAINT DF_dim_usuario_carga DEFAULT (SYSDATETIME()),
        fecha_actualizacion  DATETIME2(0)   NULL
    );
GO

/* ---------------------------------------------------------------------
   4. Miembros desconocidos (clave 0)
   Los eventos de tablero de la maqueta no tienen luminaria ni estado:
   apuntan al miembro 0 en lugar de dejar la clave nula.
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dim_tipo_evento WHERE tipo_evento_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_tipo_evento ON;
    INSERT INTO dbo.dim_tipo_evento (tipo_evento_key, tipo_evento_id, codigo, nombre, categoria)
    VALUES (0, 0, 'N/A', N'Desconocido', 'N/A');
    SET IDENTITY_INSERT dbo.dim_tipo_evento OFF;
END
IF NOT EXISTS (SELECT 1 FROM dbo.dim_proceso WHERE proceso_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_proceso ON;
    INSERT INTO dbo.dim_proceso (proceso_key, proceso_id, codigo, nombre, tipo_operacion, es_automatico, responsable_login, responsable_nombre, usuarios_asignados)
    VALUES (0, 0, 'N/A', N'Desconocido', 'N/A', 0, 'N/A', N'N/A', 0);
    SET IDENTITY_INSERT dbo.dim_proceso OFF;
END
IF NOT EXISTS (SELECT 1 FROM dbo.dim_usuario WHERE usuario_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_usuario ON;
    INSERT INTO dbo.dim_usuario (usuario_key, usuario_id, login, nombre, rol_codigo, rol_nombre, cargo, es_automatico, es_tecnico,
                                 tecnico_codigo, especialidad, procesos_responsable, activo)
    VALUES (0, 0, 'N/A', N'Sin usuario', 'N/A', N'N/A', N'N/A', 0, 0, NULL, NULL, N'N/A', 0);
    SET IDENTITY_INSERT dbo.dim_usuario OFF;
END
IF NOT EXISTS (SELECT 1 FROM dbo.dim_luminaria WHERE luminaria_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_luminaria ON;
    INSERT INTO dbo.dim_luminaria (luminaria_key, luminaria_id, codigo, modelo_codigo, modelo_descripcion, tecnologia, potencia_nominal_w,
                                   flujo_lm, vida_util_h, es_fisica, tablero, posicion_cm, fecha_instalacion, activa)
    VALUES (0, 0, 'N/A', 'N/A', N'Sin luminaria (evento de tablero o de zona)', 'N/A', 0, 0, 0, 0, NULL, NULL, '19000101', 0);
    SET IDENTITY_INSERT dbo.dim_luminaria OFF;
END
IF NOT EXISTS (SELECT 1 FROM dbo.dim_estado_operativo WHERE estado_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_estado_operativo ON;
    INSERT INTO dbo.dim_estado_operativo (estado_key, estado_id, codigo, nombre, categoria, brillo_referencia_pct)
    VALUES (0, 0, 'N/A', N'Sin estado (el evento no cambia el estado)', 'N/A', 0);
    SET IDENTITY_INSERT dbo.dim_estado_operativo OFF;
END
GO

/* ---------------------------------------------------------------------
   5. Hecho de eventos
   Grano: un evento operativo del modelo relacional (evento_id).
   Medidas: cantidad_eventos (aditiva, siempre 1), es_critico (aditiva),
            variacion_brillo_pct y minutos_desde_anterior (no aditivas: se promedian).
   Dimensiones degeneradas: evento_id, falla_id, mantenimiento_id, fecha_hora,
            accion_homologada y detalle.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.fact_evento_operativo', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.fact_evento_operativo (
        evento_key              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_evento_operativo PRIMARY KEY,
        evento_id               BIGINT          NOT NULL,
        tiempo_key              INT             NOT NULL CONSTRAINT FK_fev_tiempo REFERENCES dbo.dim_tiempo (tiempo_key),
        hora_key                SMALLINT        NOT NULL CONSTRAINT FK_fev_hora REFERENCES dbo.dim_hora (hora_key),
        luminaria_key           INT             NOT NULL CONSTRAINT FK_fev_luminaria REFERENCES dbo.dim_luminaria (luminaria_key),
        ubicacion_key           INT             NOT NULL CONSTRAINT FK_fev_ubicacion REFERENCES dbo.dim_ubicacion (ubicacion_key),
        tipo_evento_key         INT             NOT NULL CONSTRAINT FK_fev_tipo REFERENCES dbo.dim_tipo_evento (tipo_evento_key),
        proceso_key             INT             NOT NULL CONSTRAINT FK_fev_proceso REFERENCES dbo.dim_proceso (proceso_key),
        usuario_key             INT             NOT NULL CONSTRAINT FK_fev_usuario REFERENCES dbo.dim_usuario (usuario_key),
        origen_key              INT             NOT NULL CONSTRAINT FK_fev_origen REFERENCES dbo.dim_origen (origen_key),
        estado_anterior_key     INT             NOT NULL CONSTRAINT FK_fev_estado_anterior REFERENCES dbo.dim_estado_operativo (estado_key),
        estado_nuevo_key        INT             NOT NULL CONSTRAINT FK_fev_estado_nuevo REFERENCES dbo.dim_estado_operativo (estado_key),
        fecha_hora              DATETIME        NOT NULL,
        accion_homologada       NVARCHAR(20)    NOT NULL,
        detalle                 NVARCHAR(200)   NOT NULL,
        falla_id                INT             NULL,
        mantenimiento_id        INT             NULL,
        cantidad_eventos        TINYINT         NOT NULL,
        es_critico              TINYINT         NOT NULL,
        variacion_brillo_pct    DECIMAL(6,1)    NULL,
        minutos_desde_anterior  INT             NULL,
        ejecucion_id            INT             NOT NULL CONSTRAINT FK_fev_ejecucion REFERENCES dbo.etl_ejecucion (ejecucion_id),
        fecha_carga             DATETIME2(0)    NOT NULL CONSTRAINT DF_fev_fecha_carga DEFAULT (SYSDATETIME())
    );
    CREATE UNIQUE INDEX UX_fev_evento ON dbo.fact_evento_operativo (evento_id);
    CREATE INDEX IX_fev_tiempo ON dbo.fact_evento_operativo (tiempo_key, hora_key) INCLUDE (tipo_evento_key, proceso_key, ubicacion_key);
    CREATE INDEX IX_fev_tipo ON dbo.fact_evento_operativo (tipo_evento_key) INCLUDE (accion_homologada, origen_key);
    CREATE INDEX IX_fev_ejecucion ON dbo.fact_evento_operativo (ejecucion_id);
END
GO

/* ---------------------------------------------------------------------
   6. Descripciones para el explorador del tablero
   --------------------------------------------------------------------- */
EXEC dbo.sp_describir_tabla N'dim_tipo_evento', N'Tipos de evento operativo con su categoría (operación, sensor, falla, mantenimiento, comunicación).', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_proceso', N'Procesos de la operación con su tipo (monitoreo, control, atención, gestión, consumo, seguimiento) y su responsable.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'dim_usuario', N'Usuarios con su rol y cargo; incluye al usuario SISTEMA de las acciones automáticas.', N'DIMENSION';
EXEC dbo.sp_describir_tabla N'fact_evento_operativo', N'Hecho de eventos: una fila por evento operativo, con su proceso, usuario responsable y acción homologada.', N'HECHO';
EXEC dbo.sp_describir_tabla N'etl_rechazo', N'Filas rechazadas por el ETL (mediciones o eventos) con el motivo.', N'ETL';
EXEC dbo.sp_describir_tabla N'etl_control', N'Marcas de agua: última medición y último evento cargados (evitan duplicados en ejecuciones posteriores).', N'ETL';
GO

SELECT 'dim_tipo_evento' AS tabla, COUNT(*) AS filas FROM dbo.dim_tipo_evento
UNION ALL SELECT 'dim_proceso', COUNT(*) FROM dbo.dim_proceso
UNION ALL SELECT 'dim_usuario', COUNT(*) FROM dbo.dim_usuario
UNION ALL SELECT 'fact_evento_operativo', COUNT(*) FROM dbo.fact_evento_operativo;
-- Antes del ETL: 1 fila (miembro desconocido) en cada dimensión y 0 eventos.
GO
PRINT N'Estrella de eventos creada. Ejecute ahora 06_etl_procedimientos.sql (versión actualizada).';
GO
