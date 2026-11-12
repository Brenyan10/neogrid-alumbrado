/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   10_usuarios_procesos.sql
   Completa el modelo relacional con los USUARIOS, sus ROLES, los
   PROCESOS de la operación y las RESPONSABILIDADES de cada usuario en
   cada proceso. Liga los usuarios con sus acciones:

     · tipo_evento.proceso_id          cada tipo de evento pertenece a un proceso
     · falla.usuario_registra_id       quién registró / validó la falla
     · mantenimiento.usuario_programa_id  quién programó el mantenimiento
     · usuario.tecnico_id              el técnico que ejecuta un mantenimiento es un usuario

   También crea dbo.fn_etl_extraccion_eventos, la consulta de extracción
   de eventos que usa el ETL (SSIS y T-SQL).

   NO borra ni regenera datos: las mediciones y eventos existentes se
   conservan. Se puede ejecutar varias veces (cada paso revisa si ya
   está hecho). Requiere: 01, 02 y 03.
   Si se vuelve a ejecutar el script 03, ejecute de nuevo este script
   para reasignar los usuarios de las fallas y mantenimientos simulados.
   ===================================================================== */
USE NeoGridRelacional;
GO
SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   1. Tablas nuevas
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.rol', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.rol (
        rol_id          TINYINT        NOT NULL CONSTRAINT PK_rol PRIMARY KEY,
        codigo          VARCHAR(15)    NOT NULL CONSTRAINT UQ_rol_codigo UNIQUE,
        nombre          NVARCHAR(60)   NOT NULL,
        descripcion     NVARCHAR(200)  NOT NULL,
        es_automatico   BIT            NOT NULL CONSTRAINT DF_rol_automatico DEFAULT (0)
    );
END

IF OBJECT_ID(N'dbo.proceso', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.proceso (
        proceso_id       TINYINT        NOT NULL CONSTRAINT PK_proceso PRIMARY KEY,
        codigo           VARCHAR(15)    NOT NULL CONSTRAINT UQ_proceso_codigo UNIQUE,
        nombre           NVARCHAR(80)   NOT NULL,
        tipo_operacion   VARCHAR(12)    NOT NULL CONSTRAINT CK_proceso_tipo
                         CHECK (tipo_operacion IN ('MONITOREO', 'CONTROL', 'ATENCION', 'GESTION', 'CONSUMO', 'SEGUIMIENTO')),
        descripcion      NVARCHAR(250)  NOT NULL,
        es_automatico    BIT            NOT NULL
    );
END

IF OBJECT_ID(N'dbo.usuario', N'U') IS NULL
BEGIN
    /* Un técnico también es usuario. Para no repetir su nombre en dos tablas,
       el nombre de un usuario técnico se toma de dbo.tecnico (vista vw_usuario):
       la restricción CK_usuario_nombre obliga a usar una sola de las dos fuentes. */
    CREATE TABLE dbo.usuario (
        usuario_id    SMALLINT       NOT NULL CONSTRAINT PK_usuario PRIMARY KEY,
        login         VARCHAR(20)    NOT NULL CONSTRAINT UQ_usuario_login UNIQUE,
        nombre        NVARCHAR(60)   NULL,
        rol_id        TINYINT        NOT NULL CONSTRAINT FK_usuario_rol REFERENCES dbo.rol (rol_id),
        tecnico_id    TINYINT        NULL CONSTRAINT FK_usuario_tecnico REFERENCES dbo.tecnico (tecnico_id),
        cargo         NVARCHAR(80)   NOT NULL,
        fecha_alta    DATE           NOT NULL,
        activo        BIT            NOT NULL CONSTRAINT DF_usuario_activo DEFAULT (1),
        CONSTRAINT CK_usuario_nombre CHECK ((tecnico_id IS NULL AND nombre IS NOT NULL) OR (tecnico_id IS NOT NULL AND nombre IS NULL))
    );
    CREATE UNIQUE INDEX UX_usuario_tecnico ON dbo.usuario (tecnico_id) WHERE tecnico_id IS NOT NULL;
    CREATE INDEX IX_usuario_rol ON dbo.usuario (rol_id);
END

IF OBJECT_ID(N'dbo.usuario_proceso', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.usuario_proceso (
        usuario_id         SMALLINT       NOT NULL CONSTRAINT FK_usuario_proceso_usuario REFERENCES dbo.usuario (usuario_id),
        proceso_id         TINYINT        NOT NULL CONSTRAINT FK_usuario_proceso_proceso REFERENCES dbo.proceso (proceso_id),
        responsabilidad    VARCHAR(12)    NOT NULL CONSTRAINT CK_usuario_proceso_resp
                           CHECK (responsabilidad IN ('RESPONSABLE', 'EJECUTOR', 'SUPERVISOR', 'CONSULTA')),
        funcion            NVARCHAR(200)  NOT NULL,
        fecha_asignacion   DATE           NOT NULL,
        CONSTRAINT PK_usuario_proceso PRIMARY KEY (usuario_id, proceso_id)
    );
    -- Regla de negocio: cada proceso tiene exactamente un responsable
    CREATE UNIQUE INDEX UX_usuario_proceso_responsable ON dbo.usuario_proceso (proceso_id) WHERE responsabilidad = 'RESPONSABLE';
    CREATE INDEX IX_usuario_proceso_proceso ON dbo.usuario_proceso (proceso_id);
END
GO

/* ---------------------------------------------------------------------
   2. Catálogos (MERGE: se pueden volver a ejecutar sin duplicar)
   --------------------------------------------------------------------- */
MERGE dbo.rol AS t
USING (VALUES
 (1, 'SISTEMA',       N'Sistema automático',             N'Procesos sin intervención humana: controladores ESP32, suscriptor MQTT, puente y ETL programado.', 1),
 (2, 'ADMINISTRADOR', N'Administrador de la plataforma', N'Configura las reglas de control, administra las bases de datos y el despliegue del tablero.',  0),
 (3, 'ANALISTA',      N'Analista de datos',              N'Ejecuta y valida el ETL, mantiene el data warehouse y analiza consumo y operación.',          0),
 (4, 'OPERADOR',      N'Operador del centro de control', N'Vigila la red en su turno y registra o valida las fallas detectadas.',                        0),
 (5, 'SUPERVISOR',    N'Supervisor de mantenimiento',    N'Prioriza la atención de fallas y programa los mantenimientos.',                                0),
 (6, 'TECNICO',       N'Técnico de campo',               N'Ejecuta los mantenimientos preventivos y correctivos asignados.',                              0)
) AS s (rol_id, codigo, nombre, descripcion, es_automatico)
ON t.rol_id = s.rol_id
WHEN MATCHED THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, descripcion = s.descripcion, es_automatico = s.es_automatico
WHEN NOT MATCHED THEN INSERT (rol_id, codigo, nombre, descripcion, es_automatico)
                      VALUES (s.rol_id, s.codigo, s.nombre, s.descripcion, s.es_automatico);

MERGE dbo.proceso AS t
USING (VALUES
 (1, 'MON_RED',       N'Monitoreo de la red y de los sensores',          'MONITOREO',   N'Lectura de LDR y PIR, detección de presencia, cambios de luz ambiente y estado de conexión de los módulos.', 1),
 (2, 'CTRL_BRILLO',   N'Control adaptativo del alumbrado',               'CONTROL',     N'Encendido, apagado, nivel de brillo por franja y presencia, y modo ahorro.',                                1),
 (3, 'ATN_FALLAS',    N'Atención de fallas',                             'ATENCION',    N'Detección, registro, validación y cierre de fallas de luminarias, sensores y comunicación.',                0),
 (4, 'GES_MANT',      N'Gestión del mantenimiento',                      'GESTION',     N'Programación, asignación y ejecución de mantenimientos preventivos y correctivos.',                         0),
 (5, 'CON_ENERGIA',   N'Cálculo y control del consumo energético',       'CONSUMO',     N'Cálculo del consumo diario por luminaria, energía de referencia sin control y ahorro.',                    1),
 (6, 'SEG_ANALITICA', N'Seguimiento y análisis de la operación',         'SEGUIMIENTO', N'ETL hacia el data warehouse, validación de calidad, tablero e indicadores.',                                0)
) AS s (proceso_id, codigo, nombre, tipo_operacion, descripcion, es_automatico)
ON t.proceso_id = s.proceso_id
WHEN MATCHED THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, tipo_operacion = s.tipo_operacion,
                             descripcion = s.descripcion, es_automatico = s.es_automatico
WHEN NOT MATCHED THEN INSERT (proceso_id, codigo, nombre, tipo_operacion, descripcion, es_automatico)
                      VALUES (s.proceso_id, s.codigo, s.nombre, s.tipo_operacion, s.descripcion, s.es_automatico);

/* Usuarios: 1 automático, 5 personas del equipo de operación y los 5 técnicos (nombre en dbo.tecnico) */
MERGE dbo.usuario AS t
USING (VALUES
 (CAST(1 AS SMALLINT),  'sistema',        N'Sistema NeoGrid',  1, CAST(NULL AS TINYINT), N'Controladores, puente de la maqueta y ETL automático', '20260401'),
 (CAST(2 AS SMALLINT),  'bsanchez',       N'Brayan Sánchez',   2, NULL,                  N'Administrador de la plataforma',                       '20260401'),
 (CAST(3 AS SMALLINT),  'earevalo',       N'Elkin Arévalo',    3, NULL,                  N'Analista de datos',                                    '20260401'),
 (CAST(4 AS SMALLINT),  'agomez',         N'Andrea Gómez',     4, NULL,                  N'Operadora del centro de control (turno 06:00–18:00)',  '20260415'),
 (CAST(5 AS SMALLINT),  'jcastro',        N'Julián Castro',    4, NULL,                  N'Operador del centro de control (turno 18:00–06:00)',   '20260415'),
 (CAST(6 AS SMALLINT),  'mrojas',         N'Miguel Rojas',     5, NULL,                  N'Supervisor de mantenimiento',                          '20260415'),
 (CAST(7 AS SMALLINT),  'lmendez',        NULL,                6, 1,                     N'Técnica electricista',                                 '20260420'),
 (CAST(8 AS SMALLINT),  'cruiz',          NULL,                6, 2,                     N'Técnico en electrónica',                               '20260420'),
 (CAST(9 AS SMALLINT),  'dtorres',        NULL,                6, 3,                     N'Técnica en redes y comunicaciones',                    '20260420'),
 (CAST(10 AS SMALLINT), 'jpena',          NULL,                6, 4,                     N'Técnico electricista',                                 '20260420'),
 (CAST(11 AS SMALLINT), 'equipo.maqueta', NULL,                6, 5,                     N'Equipo de mantenimiento de la maqueta física',         '20260420')
) AS s (usuario_id, login, nombre, rol_id, tecnico_id, cargo, fecha_alta)
ON t.usuario_id = s.usuario_id
WHEN MATCHED THEN UPDATE SET login = s.login, nombre = s.nombre, rol_id = s.rol_id, tecnico_id = s.tecnico_id,
                             cargo = s.cargo, fecha_alta = s.fecha_alta
WHEN NOT MATCHED THEN INSERT (usuario_id, login, nombre, rol_id, tecnico_id, cargo, fecha_alta)
                      VALUES (s.usuario_id, s.login, s.nombre, s.rol_id, s.tecnico_id, s.cargo, s.fecha_alta);

/* Responsabilidades: qué hace cada usuario en cada proceso (un único RESPONSABLE por proceso) */
MERGE dbo.usuario_proceso AS t
USING (VALUES
 (CAST(1 AS SMALLINT), CAST(1 AS TINYINT), 'EJECUTOR',    N'Recibe las lecturas de LDR y PIR y el estado de conexión de los tableros.'),
 (4,  1, 'RESPONSABLE', N'Vigila la red y las alertas en el turno de día.'),
 (5,  1, 'EJECUTOR',    N'Vigila la red y las alertas en el turno de noche.'),
 (1,  2, 'EJECUTOR',    N'Enciende, apaga y ajusta el brillo según luz natural, franja horaria y presencia.'),
 (2,  2, 'RESPONSABLE', N'Define los niveles de brillo, horarios y el modo ahorro.'),
 (6,  3, 'RESPONSABLE', N'Prioriza las fallas y asigna su atención.'),
 (4,  3, 'EJECUTOR',    N'Registra y valida las fallas detectadas en el turno de día.'),
 (5,  3, 'EJECUTOR',    N'Registra y valida las fallas detectadas en el turno de noche.'),
 (1,  3, 'EJECUTOR',    N'Detecta y cierra automáticamente las fallas de comunicación y de LDR de la maqueta.'),
 (7,  3, 'EJECUTOR',    N'Repara en campo las fallas asignadas.'),
 (8,  3, 'EJECUTOR',    N'Repara en campo las fallas asignadas.'),
 (9,  3, 'EJECUTOR',    N'Repara en campo las fallas asignadas.'),
 (10, 3, 'EJECUTOR',    N'Repara en campo las fallas asignadas.'),
 (6,  4, 'RESPONSABLE', N'Programa los mantenimientos preventivos y correctivos.'),
 (7,  4, 'EJECUTOR',    N'Ejecuta los mantenimientos asignados.'),
 (8,  4, 'EJECUTOR',    N'Ejecuta los mantenimientos asignados.'),
 (9,  4, 'EJECUTOR',    N'Ejecuta los mantenimientos asignados.'),
 (10, 4, 'EJECUTOR',    N'Ejecuta los mantenimientos asignados.'),
 (11, 4, 'EJECUTOR',    N'Ejecuta el mantenimiento de la maqueta física.'),
 (3,  4, 'CONSULTA',    N'Analiza costos, retrasos y duración de los mantenimientos.'),
 (1,  5, 'EJECUTOR',    N'Calcula el consumo diario por luminaria.'),
 (3,  5, 'RESPONSABLE', N'Analiza el consumo, la energía de referencia y el ahorro.'),
 (2,  5, 'SUPERVISOR',  N'Revisa las metas de ahorro y ajusta las reglas de control.'),
 (3,  6, 'RESPONSABLE', N'Ejecuta y valida el ETL, mantiene el data warehouse y el tablero.'),
 (2,  6, 'SUPERVISOR',  N'Administra las bases de datos y el despliegue del tablero.'),
 (1,  6, 'EJECUTOR',    N'Ejecuta el ETL incremental automático desde el puente de la maqueta.'),
 (6,  6, 'CONSULTA',    N'Consulta los indicadores de fallas y mantenimiento en el tablero.')
) AS s (usuario_id, proceso_id, responsabilidad, funcion)
ON t.usuario_id = s.usuario_id AND t.proceso_id = s.proceso_id
WHEN MATCHED THEN UPDATE SET responsabilidad = s.responsabilidad, funcion = s.funcion
WHEN NOT MATCHED THEN INSERT (usuario_id, proceso_id, responsabilidad, funcion, fecha_asignacion)
                      VALUES (s.usuario_id, s.proceso_id, s.responsabilidad, s.funcion, '20260420');
GO

/* ---------------------------------------------------------------------
   3. Columnas que ligan procesos y usuarios con las acciones
   (se agregan con valor por defecto para no romper las cargas existentes:
    1 = proceso de monitoreo / usuario SISTEMA)
   --------------------------------------------------------------------- */
IF COL_LENGTH('dbo.tipo_evento', 'proceso_id') IS NULL
    ALTER TABLE dbo.tipo_evento ADD proceso_id TINYINT NOT NULL
        CONSTRAINT DF_tipo_evento_proceso DEFAULT (1)
        CONSTRAINT FK_tipo_evento_proceso REFERENCES dbo.proceso (proceso_id);

IF COL_LENGTH('dbo.falla', 'usuario_registra_id') IS NULL
    ALTER TABLE dbo.falla ADD usuario_registra_id SMALLINT NOT NULL
        CONSTRAINT DF_falla_usuario_registra DEFAULT (1)
        CONSTRAINT FK_falla_usuario_registra REFERENCES dbo.usuario (usuario_id);

IF COL_LENGTH('dbo.mantenimiento', 'usuario_programa_id') IS NULL
    ALTER TABLE dbo.mantenimiento ADD usuario_programa_id SMALLINT NOT NULL
        CONSTRAINT DF_mantenimiento_usuario_programa DEFAULT (1)
        CONSTRAINT FK_mantenimiento_usuario_programa REFERENCES dbo.usuario (usuario_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_falla_usuario_registra' AND object_id = OBJECT_ID(N'dbo.falla'))
    CREATE INDEX IX_falla_usuario_registra ON dbo.falla (usuario_registra_id);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_mantenimiento_usuario_programa' AND object_id = OBJECT_ID(N'dbo.mantenimiento'))
    CREATE INDEX IX_mantenimiento_usuario_programa ON dbo.mantenimiento (usuario_programa_id);
GO

/* ---------------------------------------------------------------------
   4. Asignación determinista de procesos y usuarios
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_asignar_responsables
AS
BEGIN
    SET NOCOUNT ON;

    /* Cada tipo de evento pertenece al proceso que lo produce */
    UPDATE dbo.tipo_evento
       SET proceso_id = CASE codigo
                            WHEN 'ENCENDIDO'            THEN 2
                            WHEN 'APAGADO'              THEN 2
                            WHEN 'CAMBIO_BRILLO'        THEN 2
                            WHEN 'MODO_AHORRO'          THEN 2
                            WHEN 'DETECCION_MOVIMIENTO' THEN 1
                            WHEN 'CAMBIO_LUZ_AMBIENTE'  THEN 1
                            WHEN 'CONEXION'             THEN 1
                            WHEN 'DESCONEXION'          THEN 1
                            WHEN 'FALLA_DETECTADA'      THEN 3
                            WHEN 'FALLA_RESUELTA'       THEN 3
                            WHEN 'INICIO_MANTENIMIENTO' THEN 4
                            WHEN 'FIN_MANTENIMIENTO'    THEN 4
                            ELSE proceso_id END;

    /* Fallas simuladas: las valida el operador del turno en que se detectan
       (06:00–17:59 Andrea Gómez, 18:00–05:59 Julián Castro).
       Fallas de la maqueta y de prueba: las registra el SISTEMA (detección automática). */
    UPDATE dbo.falla
       SET usuario_registra_id = CASE WHEN origen_id <> 1 THEN 1
                                      WHEN DATEPART(HOUR, fecha_deteccion) BETWEEN 6 AND 17 THEN 4
                                      ELSE 5 END;

    /* Mantenimientos: los preventivos los programa el supervisor;
       los correctivos, el operador del turno en que se programan. */
    UPDATE m
       SET usuario_programa_id = CASE WHEN m.origen_id <> 1 THEN 1
                                      WHEN tm.es_correctivo = 0 THEN 6
                                      WHEN DATEPART(HOUR, m.fecha_programada) BETWEEN 6 AND 17 THEN 4
                                      ELSE 5 END
      FROM dbo.mantenimiento m
      JOIN dbo.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = m.tipo_mantenimiento_id;
END
GO
EXEC dbo.sp_asignar_responsables;
GO

/* ---------------------------------------------------------------------
   5. Vista de usuarios (resuelve el nombre de los técnicos)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_usuario
AS
SELECT u.usuario_id, u.login, COALESCE(u.nombre, t.nombre) AS nombre, r.codigo AS rol_codigo, r.nombre AS rol_nombre,
       u.cargo, u.tecnico_id, t.codigo AS tecnico_codigo, t.especialidad, u.fecha_alta, u.activo
FROM dbo.usuario u
JOIN dbo.rol r ON r.rol_id = u.rol_id
LEFT JOIN dbo.tecnico t ON t.tecnico_id = u.tecnico_id;
GO

/* ---------------------------------------------------------------------
   6. Extracción de eventos para el ETL
   · luminaria y estados nulos (eventos de tablero) -> 0 (miembro desconocido del DW)
   · usuario responsable de cada evento:
       FALLA_DETECTADA       -> quien registró la falla
       FALLA_RESUELTA        -> técnico del correctivo que la cerró (o SISTEMA)
       INICIO/FIN_MANT.      -> técnico del mantenimiento
       resto                 -> SISTEMA (acciones automáticas del controlador)
   · minutos_desde_anterior: tiempo desde el evento previo del mismo poste o tablero
   · orden_duplicado > 1: mismo poste/tablero, tipo, segundo y detalle (mensaje repetido)
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_etl_extraccion_eventos (@desde_id BIGINT, @hasta_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT
    e.evento_id,
    ISNULL(e.luminaria_id, CAST(0 AS SMALLINT)) AS luminaria_id,
    e.ubicacion_id,
    e.tipo_evento_id,
    CAST(te.codigo AS NVARCHAR(25)) AS tipo_codigo,
    te.proceso_id,
    CAST(COALESCE(CASE WHEN e.tipo_evento_id = 6 THEN f.usuario_registra_id
                       WHEN e.tipo_evento_id = 7 THEN ur.usuario_id
                       WHEN e.tipo_evento_id IN (8, 9) THEN um.usuario_id END, 1) AS SMALLINT) AS usuario_id,
    e.origen_id,
    CAST(e.fecha_hora AS DATETIME) AS fecha_hora,
    CAST(CONVERT(CHAR(8), e.fecha_hora, 112) AS INT) AS tiempo_key,
    CAST(DATEPART(HOUR, e.fecha_hora) * 100 + (DATEPART(MINUTE, e.fecha_hora) / 15) * 15 AS SMALLINT) AS hora_key,
    ISNULL(e.estado_anterior_id, CAST(0 AS TINYINT)) AS estado_anterior_id,
    ISNULL(e.estado_nuevo_id, CAST(0 AS TINYINT)) AS estado_nuevo_id,
    e.brillo_anterior,
    e.brillo_nuevo,
    e.falla_id,
    e.mantenimiento_id,
    e.detalle,
    e.minutos_desde_anterior,
    CAST(e.orden_duplicado AS INT) AS orden_duplicado
FROM (
    SELECT eo.*,
           DATEDIFF(MINUTE,
                    LAG(eo.fecha_hora) OVER (PARTITION BY eo.ubicacion_id, ISNULL(eo.luminaria_id, 0) ORDER BY eo.fecha_hora, eo.evento_id),
                    eo.fecha_hora) AS minutos_desde_anterior,
           ROW_NUMBER() OVER (PARTITION BY ISNULL(eo.luminaria_id, 0), eo.ubicacion_id, eo.tipo_evento_id, eo.fecha_hora, ISNULL(eo.detalle, N'')
                              ORDER BY eo.evento_id) AS orden_duplicado
    FROM dbo.evento_operativo eo
) e
JOIN dbo.tipo_evento te ON te.tipo_evento_id = e.tipo_evento_id
LEFT JOIN dbo.falla f ON f.falla_id = e.falla_id
LEFT JOIN dbo.mantenimiento m ON m.mantenimiento_id = e.mantenimiento_id
LEFT JOIN dbo.usuario um ON um.tecnico_id = m.tecnico_id
OUTER APPLY (SELECT TOP (1) u.usuario_id
             FROM dbo.mantenimiento mc
             JOIN dbo.usuario u ON u.tecnico_id = mc.tecnico_id
             WHERE mc.falla_id = e.falla_id AND mc.estado = 'REALIZADO'
             ORDER BY mc.fecha_fin DESC, mc.mantenimiento_id DESC) ur
WHERE e.evento_id > @desde_id
  AND e.evento_id <= @hasta_id;
GO

/* ---------------------------------------------------------------------
   7. Descripciones para el explorador del tablero
   --------------------------------------------------------------------- */
EXEC dbo.sp_describir_tabla N'rol', N'Roles de los usuarios: sistema automático, administrador, analista, operador, supervisor y técnico.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'proceso', N'Procesos de la operación: monitoreo, control, atención de fallas, gestión del mantenimiento, consumo y seguimiento.', N'CATALOGO';
EXEC dbo.sp_describir_tabla N'usuario', N'Usuarios del sistema con su rol. Los técnicos son usuarios ligados a la tabla tecnico.', N'MAESTRA';
EXEC dbo.sp_describir_tabla N'usuario_proceso', N'Responsabilidad de cada usuario en cada proceso (un único responsable por proceso).', N'MAESTRA';
EXEC dbo.sp_describir_tabla N'tecnico', N'Personas o equipos que ejecutan los mantenimientos (cada uno es también un usuario).', N'CATALOGO';
GO

/* ---------------------------------------------------------------------
   8. Comprobación
   --------------------------------------------------------------------- */
SELECT 'rol' AS tabla, COUNT(*) AS filas FROM dbo.rol
UNION ALL SELECT 'proceso', COUNT(*) FROM dbo.proceso
UNION ALL SELECT 'usuario', COUNT(*) FROM dbo.usuario
UNION ALL SELECT 'usuario_proceso', COUNT(*) FROM dbo.usuario_proceso
UNION ALL SELECT 'tipo_evento sin proceso de su categoría', COUNT(*) FROM dbo.tipo_evento WHERE proceso_id = 1 AND categoria NOT IN ('SENSOR', 'COMUNICACION');
-- Esperado: rol 6 · proceso 6 · usuario 11 · usuario_proceso 27 · tipo_evento sin proceso 0

SELECT u.nombre, u.rol_nombre, COUNT(f.falla_id) AS fallas_registradas
FROM dbo.vw_usuario u LEFT JOIN dbo.falla f ON f.usuario_registra_id = u.usuario_id
GROUP BY u.usuario_id, u.nombre, u.rol_nombre
HAVING COUNT(f.falla_id) > 0
ORDER BY u.usuario_id;
GO
PRINT N'Usuarios, roles, procesos y responsabilidades listos.';
GO
