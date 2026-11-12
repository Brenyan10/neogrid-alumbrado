/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   06_etl_procedimientos.sql
   Procedimientos del ETL en NeoGridDW. Los usa el paquete SSIS
   (ETL_NeoGrid.dtsx) y también la ruta alternativa 100 % T-SQL:

     EXEC dbo.sp_etl_ejecutar_tsql;      -- ETL completo sin SSIS

   Procedimientos:
     sp_etl_iniciar                  abre una ejecución y fija las ventanas de ids (mediciones y eventos)
     sp_etl_registrar_paso           registra la duración de un paso
     sp_etl_cargar_dimensiones       MERGE (SCD tipo 1) de las 11 dimensiones que vienen del relacional
     sp_etl_cargar_hechos_tsql       extrae, transforma, valida y carga el hecho principal
     sp_etl_cargar_eventos_tsql      extrae, homologa, valida y carga el hecho de eventos
     sp_etl_cargar_hechos_secundarios  MERGE de fact_falla y fact_mantenimiento
     sp_etl_actualizar_agregados     recalcula los hechos agregados de los días afectados
     sp_etl_finalizar                cierra la ejecución, cuenta filas y mueve las marcas de agua
     sp_etl_registrar_error          marca la ejecución como fallida
     sp_etl_ejecutar_tsql            orquesta todo lo anterior
     sp_etl_reiniciar                vacía los hechos para repetir la carga completa
   Requiere: 04, 05 y 11 (y 10 en NeoGridRelacional).
   ===================================================================== */
USE NeoGridDW;
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_iniciar
    @herramienta         VARCHAR(10)   = 'TSQL',
    @paquete             NVARCHAR(100) = NULL,
    @devolver_resultado  BIT           = 0,
    @ejecucion_id        INT           = NULL OUTPUT,
    @watermark_min       INT           = NULL OUTPUT,
    @watermark_max       INT           = NULL OUTPUT,
    @evento_min          INT           = NULL OUTPUT,
    @evento_max          INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.etl_ejecucion
       SET estado = 'FALLIDA', fin = SYSDATETIME(),
           mensaje = CONCAT(ISNULL(mensaje + N' | ', N''), N'Cerrada automáticamente: quedó en curso y se inició una nueva ejecución.')
     WHERE estado = 'EN_CURSO';

    IF NOT EXISTS (SELECT 1 FROM dbo.etl_control WHERE proceso = 'FACT_OPERACION')
        INSERT INTO dbo.etl_control (proceso, ultimo_medicion_id) VALUES ('FACT_OPERACION', 0);
    IF NOT EXISTS (SELECT 1 FROM dbo.etl_control WHERE proceso = 'FACT_EVENTO')
        INSERT INTO dbo.etl_control (proceso, ultimo_medicion_id) VALUES ('FACT_EVENTO', 0);

    /* Ventana de mediciones: (última cargada, máxima actual] */
    SELECT @watermark_min = CAST(ultimo_medicion_id AS INT) FROM dbo.etl_control WHERE proceso = 'FACT_OPERACION';
    SELECT @watermark_max = CAST(ISNULL(MAX(medicion_id), 0) AS INT) FROM src.medicion;
    IF @watermark_max < @watermark_min SET @watermark_max = @watermark_min;

    /* Ventana de eventos: (último evento cargado, máximo actual] */
    SELECT @evento_min = CAST(ultimo_medicion_id AS INT) FROM dbo.etl_control WHERE proceso = 'FACT_EVENTO';
    SELECT @evento_max = CAST(ISNULL(MAX(evento_id), 0) AS INT) FROM src.evento_operativo;
    IF @evento_max < @evento_min SET @evento_max = @evento_min;

    INSERT INTO dbo.etl_ejecucion (herramienta, paquete, inicio, estado, watermark_inicial, watermark_final,
                                   evento_watermark_inicial, evento_watermark_final)
    VALUES (@herramienta, ISNULL(@paquete, N'sp_etl_ejecutar_tsql'), SYSDATETIME(), 'EN_CURSO', @watermark_min, @watermark_max,
            @evento_min, @evento_max);

    SET @ejecucion_id = CAST(SCOPE_IDENTITY() AS INT);

    IF @devolver_resultado = 1
        SELECT @ejecucion_id AS ejecucion_id, @watermark_min AS watermark_min, @watermark_max AS watermark_max,
               @evento_min AS evento_min, @evento_max AS evento_max;
END
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_registrar_paso
    @ejecucion_id INT,
    @paso         NVARCHAR(60),
    @inicio       DATETIME2(0),
    @filas        INT = NULL,
    @estado       VARCHAR(12) = 'OK',
    @mensaje      NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.etl_paso (ejecucion_id, paso, inicio, fin, filas, estado, mensaje)
    VALUES (@ejecucion_id, @paso, @inicio, SYSDATETIME(), @filas, @estado, @mensaje);
END
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_cargar_dimensiones
    @ejecucion_id     INT,
    @filas_afectadas  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    SET @filas_afectadas = 0;

    /* dim_ubicacion */
    MERGE dbo.dim_ubicacion AS t
    USING (
        SELECT u.ubicacion_id, u.codigo, u.nombre, u.tipo_via, u.longitud_m,
               z.zona_id, z.codigo AS zona_codigo, z.nombre AS zona_nombre, z.tipo_zona, CAST(z.es_fisica AS TINYINT) AS es_fisica
        FROM src.ubicacion u
        JOIN src.zona z ON z.zona_id = u.zona_id
    ) AS s
    ON t.ubicacion_id = s.ubicacion_id
    WHEN MATCHED AND EXISTS (
        SELECT s.codigo, s.nombre, s.tipo_via, s.longitud_m, s.zona_id, s.zona_codigo, s.zona_nombre, s.tipo_zona, s.es_fisica
        EXCEPT
        SELECT t.codigo, t.nombre, t.tipo_via, t.longitud_m, t.zona_id, t.zona_codigo, t.zona_nombre, t.tipo_zona, t.es_fisica)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, tipo_via = s.tipo_via, longitud_m = s.longitud_m,
                        zona_id = s.zona_id, zona_codigo = s.zona_codigo, zona_nombre = s.zona_nombre,
                        tipo_zona = s.tipo_zona, es_fisica = s.es_fisica, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (ubicacion_id, codigo, nombre, tipo_via, longitud_m, zona_id, zona_codigo, zona_nombre, tipo_zona, es_fisica)
             VALUES (s.ubicacion_id, s.codigo, s.nombre, s.tipo_via, s.longitud_m, s.zona_id, s.zona_codigo, s.zona_nombre, s.tipo_zona, s.es_fisica);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_luminaria */
    MERGE dbo.dim_luminaria AS t
    USING (
        SELECT l.luminaria_id, l.codigo, mo.codigo AS modelo_codigo, mo.descripcion AS modelo_descripcion, mo.tecnologia,
               mo.potencia_nominal_w, mo.flujo_lm, mo.vida_util_h, CAST(l.es_fisica AS TINYINT) AS es_fisica,
               l.tablero, l.posicion_cm, l.fecha_instalacion, CAST(l.activa AS TINYINT) AS activa
        FROM src.luminaria l
        JOIN src.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
    ) AS s
    ON t.luminaria_id = s.luminaria_id
    WHEN MATCHED AND EXISTS (
        SELECT s.codigo, s.modelo_codigo, s.modelo_descripcion, s.tecnologia, s.potencia_nominal_w, s.flujo_lm, s.vida_util_h,
               s.es_fisica, s.tablero, s.posicion_cm, s.fecha_instalacion, s.activa
        EXCEPT
        SELECT t.codigo, t.modelo_codigo, t.modelo_descripcion, t.tecnologia, t.potencia_nominal_w, t.flujo_lm, t.vida_util_h,
               t.es_fisica, t.tablero, t.posicion_cm, t.fecha_instalacion, t.activa)
        THEN UPDATE SET codigo = s.codigo, modelo_codigo = s.modelo_codigo, modelo_descripcion = s.modelo_descripcion,
                        tecnologia = s.tecnologia, potencia_nominal_w = s.potencia_nominal_w, flujo_lm = s.flujo_lm,
                        vida_util_h = s.vida_util_h, es_fisica = s.es_fisica, tablero = s.tablero, posicion_cm = s.posicion_cm,
                        fecha_instalacion = s.fecha_instalacion, activa = s.activa, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (luminaria_id, codigo, modelo_codigo, modelo_descripcion, tecnologia, potencia_nominal_w, flujo_lm, vida_util_h,
                     es_fisica, tablero, posicion_cm, fecha_instalacion, activa)
             VALUES (s.luminaria_id, s.codigo, s.modelo_codigo, s.modelo_descripcion, s.tecnologia, s.potencia_nominal_w, s.flujo_lm,
                     s.vida_util_h, s.es_fisica, s.tablero, s.posicion_cm, s.fecha_instalacion, s.activa);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_sensor (el miembro 0 "sin sensor" no se toca) */
    MERGE dbo.dim_sensor AS t
    USING (
        SELECT s.sensor_id, s.codigo, ts.codigo AS tipo_codigo, ts.nombre AS tipo_nombre, ts.magnitud, ts.unidad,
               CAST(s.es_fisico AS TINYINT) AS es_fisico, s.pin_gpio, s.modelo, u.codigo AS ubicacion_codigo,
               z.codigo AS zona_codigo, CAST(s.activo AS TINYINT) AS activo
        FROM src.sensor s
        JOIN src.tipo_sensor ts ON ts.tipo_sensor_id = s.tipo_sensor_id
        JOIN src.ubicacion u ON u.ubicacion_id = s.ubicacion_id
        JOIN src.zona z ON z.zona_id = u.zona_id
    ) AS s
    ON t.sensor_id = s.sensor_id
    WHEN MATCHED AND EXISTS (
        SELECT s.codigo, s.tipo_codigo, s.tipo_nombre, s.magnitud, s.unidad, s.es_fisico, s.pin_gpio, s.modelo, s.ubicacion_codigo, s.zona_codigo, s.activo
        EXCEPT
        SELECT t.codigo, t.tipo_codigo, t.tipo_nombre, t.magnitud, t.unidad, t.es_fisico, t.pin_gpio, t.modelo, t.ubicacion_codigo, t.zona_codigo, t.activo)
        THEN UPDATE SET codigo = s.codigo, tipo_codigo = s.tipo_codigo, tipo_nombre = s.tipo_nombre, magnitud = s.magnitud,
                        unidad = s.unidad, es_fisico = s.es_fisico, pin_gpio = s.pin_gpio, modelo = s.modelo,
                        ubicacion_codigo = s.ubicacion_codigo, zona_codigo = s.zona_codigo, activo = s.activo,
                        fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (sensor_id, codigo, tipo_codigo, tipo_nombre, magnitud, unidad, es_fisico, pin_gpio, modelo, ubicacion_codigo, zona_codigo, activo)
             VALUES (s.sensor_id, s.codigo, s.tipo_codigo, s.tipo_nombre, s.magnitud, s.unidad, s.es_fisico, s.pin_gpio, s.modelo,
                     s.ubicacion_codigo, s.zona_codigo, s.activo);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_estado_operativo */
    MERGE dbo.dim_estado_operativo AS t
    USING (SELECT estado_id, codigo, nombre, categoria, brillo_referencia_pct FROM src.estado_operativo) AS s
    ON t.estado_id = s.estado_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.categoria, s.brillo_referencia_pct
                             EXCEPT SELECT t.codigo, t.nombre, t.categoria, t.brillo_referencia_pct)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, categoria = s.categoria,
                        brillo_referencia_pct = s.brillo_referencia_pct, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (estado_id, codigo, nombre, categoria, brillo_referencia_pct)
             VALUES (s.estado_id, s.codigo, s.nombre, s.categoria, s.brillo_referencia_pct);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_origen */
    MERGE dbo.dim_origen AS t
    USING (SELECT origen_id, codigo, nombre, descripcion FROM src.origen_dato) AS s
    ON t.origen_id = s.origen_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.descripcion EXCEPT SELECT t.codigo, t.nombre, t.descripcion)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, descripcion = s.descripcion, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (origen_id, codigo, nombre, descripcion) VALUES (s.origen_id, s.codigo, s.nombre, s.descripcion);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_tipo_falla */
    MERGE dbo.dim_tipo_falla AS t
    USING (SELECT tipo_falla_id, codigo, nombre, severidad, CAST(deja_fuera_servicio AS TINYINT) AS deja_fuera_servicio FROM src.tipo_falla) AS s
    ON t.tipo_falla_id = s.tipo_falla_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.severidad, s.deja_fuera_servicio
                             EXCEPT SELECT t.codigo, t.nombre, t.severidad, t.deja_fuera_servicio)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, severidad = s.severidad,
                        deja_fuera_servicio = s.deja_fuera_servicio, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (tipo_falla_id, codigo, nombre, severidad, deja_fuera_servicio)
             VALUES (s.tipo_falla_id, s.codigo, s.nombre, s.severidad, s.deja_fuera_servicio);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_tipo_mantenimiento */
    MERGE dbo.dim_tipo_mantenimiento AS t
    USING (SELECT tipo_mantenimiento_id, codigo, nombre, CAST(es_correctivo AS TINYINT) AS es_correctivo, duracion_estimada_min FROM src.tipo_mantenimiento) AS s
    ON t.tipo_mantenimiento_id = s.tipo_mantenimiento_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.es_correctivo, s.duracion_estimada_min
                             EXCEPT SELECT t.codigo, t.nombre, t.es_correctivo, t.duracion_estimada_min)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, es_correctivo = s.es_correctivo,
                        duracion_estimada_min = s.duracion_estimada_min, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (tipo_mantenimiento_id, codigo, nombre, es_correctivo, duracion_estimada_min)
             VALUES (s.tipo_mantenimiento_id, s.codigo, s.nombre, s.es_correctivo, s.duracion_estimada_min);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_tecnico (el miembro 0 "sin asignar" no se toca) */
    MERGE dbo.dim_tecnico AS t
    USING (SELECT tecnico_id, codigo, nombre, especialidad, CAST(activo AS TINYINT) AS activo FROM src.tecnico) AS s
    ON t.tecnico_id = s.tecnico_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.especialidad, s.activo EXCEPT SELECT t.codigo, t.nombre, t.especialidad, t.activo)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, especialidad = s.especialidad, activo = s.activo, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (tecnico_id, codigo, nombre, especialidad, activo) VALUES (s.tecnico_id, s.codigo, s.nombre, s.especialidad, s.activo);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_tipo_evento (el miembro 0 "desconocido" no se toca) */
    MERGE dbo.dim_tipo_evento AS t
    USING (SELECT tipo_evento_id, codigo, nombre, categoria FROM src.tipo_evento) AS s
    ON t.tipo_evento_id = s.tipo_evento_id
    WHEN MATCHED AND EXISTS (SELECT s.codigo, s.nombre, s.categoria EXCEPT SELECT t.codigo, t.nombre, t.categoria)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, categoria = s.categoria, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (tipo_evento_id, codigo, nombre, categoria) VALUES (s.tipo_evento_id, s.codigo, s.nombre, s.categoria);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_proceso: el responsable y el número de usuarios se desnormalizan desde usuario_proceso */
    MERGE dbo.dim_proceso AS t
    USING (
        SELECT p.proceso_id, p.codigo, p.nombre, p.tipo_operacion, CAST(p.es_automatico AS TINYINT) AS es_automatico,
               ISNULL(r.login, 'N/A') AS responsable_login, ISNULL(r.nombre, N'Sin responsable') AS responsable_nombre,
               ISNULL(n.usuarios, 0) AS usuarios_asignados
        FROM src.proceso p
        OUTER APPLY (SELECT TOP (1) vu.login, vu.nombre
                     FROM src.usuario_proceso up JOIN src.vw_usuario vu ON vu.usuario_id = up.usuario_id
                     WHERE up.proceso_id = p.proceso_id AND up.responsabilidad = 'RESPONSABLE') r
        OUTER APPLY (SELECT COUNT(*) AS usuarios FROM src.usuario_proceso up WHERE up.proceso_id = p.proceso_id) n
    ) AS s
    ON t.proceso_id = s.proceso_id
    WHEN MATCHED AND EXISTS (
        SELECT s.codigo, s.nombre, s.tipo_operacion, s.es_automatico, s.responsable_login, s.responsable_nombre, s.usuarios_asignados
        EXCEPT
        SELECT t.codigo, t.nombre, t.tipo_operacion, t.es_automatico, t.responsable_login, t.responsable_nombre, t.usuarios_asignados)
        THEN UPDATE SET codigo = s.codigo, nombre = s.nombre, tipo_operacion = s.tipo_operacion, es_automatico = s.es_automatico,
                        responsable_login = s.responsable_login, responsable_nombre = s.responsable_nombre,
                        usuarios_asignados = s.usuarios_asignados, fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (proceso_id, codigo, nombre, tipo_operacion, es_automatico, responsable_login, responsable_nombre, usuarios_asignados)
             VALUES (s.proceso_id, s.codigo, s.nombre, s.tipo_operacion, s.es_automatico, s.responsable_login, s.responsable_nombre,
                     s.usuarios_asignados);
    SET @filas_afectadas += @@ROWCOUNT;

    /* dim_usuario: rol, cargo y técnico desnormalizados; procesos de los que es responsable */
    MERGE dbo.dim_usuario AS t
    USING (
        SELECT vu.usuario_id, vu.login, vu.nombre, vu.rol_codigo, vu.rol_nombre, vu.cargo,
               CAST(r.es_automatico AS TINYINT) AS es_automatico,
               CAST(CASE WHEN vu.tecnico_id IS NULL THEN 0 ELSE 1 END AS TINYINT) AS es_tecnico,
               vu.tecnico_codigo, vu.especialidad,
               CAST(ISNULL(pr.lista, N'Ninguno') AS NVARCHAR(200)) AS procesos_responsable,
               CAST(vu.activo AS TINYINT) AS activo
        FROM src.vw_usuario vu
        JOIN src.rol r ON r.codigo = vu.rol_codigo
        OUTER APPLY (SELECT STRING_AGG(CAST(p.codigo AS NVARCHAR(15)), N', ') WITHIN GROUP (ORDER BY p.proceso_id) AS lista
                     FROM src.usuario_proceso up JOIN src.proceso p ON p.proceso_id = up.proceso_id
                     WHERE up.usuario_id = vu.usuario_id AND up.responsabilidad = 'RESPONSABLE') pr
    ) AS s
    ON t.usuario_id = s.usuario_id
    WHEN MATCHED AND EXISTS (
        SELECT s.login, s.nombre, s.rol_codigo, s.rol_nombre, s.cargo, s.es_automatico, s.es_tecnico, s.tecnico_codigo,
               s.especialidad, s.procesos_responsable, s.activo
        EXCEPT
        SELECT t.login, t.nombre, t.rol_codigo, t.rol_nombre, t.cargo, t.es_automatico, t.es_tecnico, t.tecnico_codigo,
               t.especialidad, t.procesos_responsable, t.activo)
        THEN UPDATE SET login = s.login, nombre = s.nombre, rol_codigo = s.rol_codigo, rol_nombre = s.rol_nombre, cargo = s.cargo,
                        es_automatico = s.es_automatico, es_tecnico = s.es_tecnico, tecnico_codigo = s.tecnico_codigo,
                        especialidad = s.especialidad, procesos_responsable = s.procesos_responsable, activo = s.activo,
                        fecha_actualizacion = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (usuario_id, login, nombre, rol_codigo, rol_nombre, cargo, es_automatico, es_tecnico, tecnico_codigo,
                     especialidad, procesos_responsable, activo)
             VALUES (s.usuario_id, s.login, s.nombre, s.rol_codigo, s.rol_nombre, s.cargo, s.es_automatico, s.es_tecnico,
                     s.tecnico_codigo, s.especialidad, s.procesos_responsable, s.activo);
    SET @filas_afectadas += @@ROWCOUNT;

    UPDATE dbo.etl_ejecucion SET dimensiones_actualizadas = @filas_afectadas WHERE ejecucion_id = @ejecucion_id;
    EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Dimensiones (MERGE SCD1)', @t, @filas_afectadas, 'OK', NULL;
END
GO

/* ------------------------------------------------------------------
   Hecho principal en T-SQL. Aplica las MISMAS reglas que el flujo de
   datos de SSIS (ver la guía): validación, imputación, cálculo de
   indicadores, búsqueda de claves y control de duplicados.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_cargar_hechos_tsql
    @ejecucion_id    INT,
    @filas_leidas    INT = NULL OUTPUT,
    @filas_omitidas  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    DECLARE @wmin BIGINT, @wmax BIGINT, @insertadas INT, @rechazadas INT;

    SELECT @wmin = watermark_inicial, @wmax = watermark_final
    FROM dbo.etl_ejecucion WHERE ejecucion_id = @ejecucion_id;

    /* E · Extracción ------------------------------------------------- */
    IF OBJECT_ID('tempdb..#ext') IS NOT NULL DROP TABLE #ext;
    SELECT x.* INTO #ext FROM src.fn_etl_extraccion(@wmin, @wmax) AS x;
    SET @filas_leidas = @@ROWCOUNT;

    /* T · Validación, limpieza, cálculos y claves -------------------- */
    IF OBJECT_ID('tempdb..#trf') IS NOT NULL DROP TABLE #trf;
    SELECT
        e.medicion_id,
        e.luminaria_id,
        e.fecha_hora,
        e.brillo_pct AS brillo_original,
        v.motivo,
        dl.luminaria_key,
        du.ubicacion_key,
        dsl.sensor_key AS sensor_luz_key,
        dsp.sensor_key AS sensor_presencia_key,
        de.estado_key,
        dor.origen_key,
        dt.tiempo_key,
        dh.hora_key,
        e.es_noche,
        CAST(CASE WHEN e.brillo_pct > 0 THEN 1 ELSE 0 END AS TINYINT) AS encendida,
        CAST(CASE WHEN e.estado_id IN (7, 8) THEN 1 ELSE 0 END AS TINYINT) AS en_falla,
        e.es_anomala,
        c1.nivel_luz_lux,
        c1.detecciones,
        CAST(ISNULL(e.brillo_pct, 0) AS DECIMAL(5,1)) AS brillo_pct,
        c1.tension_v,
        c2.corriente_a,
        c1.potencia_w,
        c2.energia_wh,
        c1.energia_referencia_wh,
        CAST(c1.energia_referencia_wh - c2.energia_wh AS DECIMAL(10,3)) AS ahorro_wh,
        c1.temperatura_c,
        CAST(1 + c1.fue_imputado + 2 * e.es_anomala AS TINYINT) AS calidad_key,
        CAST(0 AS TINYINT) AS ya_cargado
    INTO #trf
    FROM #ext e
    CROSS APPLY (SELECT CAST(CASE
            WHEN e.orden_duplicado > 1 THEN N'DUPLICADO'
            WHEN e.fecha_hora < '20260101' OR e.fecha_hora > DATEADD(DAY, 1, GETDATE()) THEN N'FECHA_INVALIDA'
            WHEN e.brillo_pct IS NULL OR e.brillo_pct < 0 OR e.brillo_pct > 100 THEN N'BRILLO_FUERA_DE_RANGO'
            WHEN e.tension_v < 0 OR e.tension_v > 400 OR e.nivel_luz_lux < 0 OR e.detecciones < 0 OR e.potencia_w < 0 THEN N'VALOR_IMPOSIBLE'
        END AS NVARCHAR(40)) AS motivo) v
    CROSS APPLY (SELECT
            CAST(COALESCE(e.nivel_luz_lux, e.lux_referencia, 0) AS DECIMAL(9,1)) AS nivel_luz_lux,
            CAST(ISNULL(e.detecciones, 0) AS SMALLINT) AS detecciones,
            CAST(ISNULL(e.tension_v, 220) AS DECIMAL(6,2)) AS tension_v,
            CAST(ISNULL(e.potencia_w, e.potencia_nominal_w * ISNULL(e.brillo_pct, 0) / 100 + 1.5) AS DECIMAL(8,2)) AS potencia_w,
            CAST(COALESCE(e.temperatura_c, e.temperatura_ambiente, 14) AS DECIMAL(5,1)) AS temperatura_c,
            CAST(CASE WHEN e.es_noche = 1 THEN (e.potencia_nominal_w + 1.5) * 0.25 ELSE 0.375 END AS DECIMAL(10,3)) AS energia_referencia_wh,
            CAST(CASE WHEN e.nivel_luz_lux IS NULL OR e.tension_v IS NULL OR e.corriente_a IS NULL OR e.potencia_w IS NULL
                        OR e.energia_wh IS NULL OR e.temperatura_c IS NULL OR e.detecciones IS NULL OR e.energia_wh < 0
                   THEN 1 ELSE 0 END AS TINYINT) AS fue_imputado
        ) c1
    CROSS APPLY (SELECT
            CAST(CASE WHEN e.energia_wh IS NULL OR e.energia_wh < 0 THEN c1.potencia_w * 0.25 ELSE e.energia_wh END AS DECIMAL(10,3)) AS energia_wh,
            CAST(CASE WHEN e.corriente_a IS NOT NULL THEN e.corriente_a
                      WHEN c1.tension_v > 0 THEN c1.potencia_w / c1.tension_v ELSE 0 END AS DECIMAL(7,3)) AS corriente_a
        ) c2
    LEFT JOIN dbo.dim_luminaria dl         ON dl.luminaria_id = e.luminaria_id
    LEFT JOIN dbo.dim_ubicacion du         ON du.ubicacion_id = e.ubicacion_id
    LEFT JOIN dbo.dim_sensor dsl           ON dsl.sensor_id = e.sensor_luz_id
    LEFT JOIN dbo.dim_sensor dsp           ON dsp.sensor_id = e.sensor_presencia_id
    LEFT JOIN dbo.dim_estado_operativo de  ON de.estado_id = e.estado_id
    LEFT JOIN dbo.dim_origen dor           ON dor.origen_id = e.origen_id
    LEFT JOIN dbo.dim_tiempo dt            ON dt.tiempo_key = e.tiempo_key AND dt.tiempo_key > 0
    LEFT JOIN dbo.dim_hora dh              ON dh.hora_key = e.hora_key;

    /* Claves que no existen en las dimensiones */
    UPDATE #trf SET motivo = N'CLAVE_SIN_DIMENSION'
    WHERE motivo IS NULL
      AND (luminaria_key IS NULL OR ubicacion_key IS NULL OR sensor_luz_key IS NULL OR sensor_presencia_key IS NULL
           OR estado_key IS NULL OR origen_key IS NULL OR tiempo_key IS NULL OR hora_key IS NULL);

    /* Filas que ya están en el hecho (re-ejecución): se omiten sin rechazarlas */
    UPDATE tr SET ya_cargado = 1
    FROM #trf tr
    WHERE EXISTS (SELECT 1 FROM dbo.fact_operacion_luminaria f WHERE f.medicion_id = tr.medicion_id);

    /* Mismo grano (luminaria + día + intervalo) ya cargado con otra medición */
    UPDATE tr SET motivo = N'DUPLICADO'
    FROM #trf tr
    WHERE tr.motivo IS NULL AND tr.ya_cargado = 0
      AND EXISTS (SELECT 1 FROM dbo.fact_operacion_luminaria f
                  WHERE f.luminaria_key = tr.luminaria_key AND f.tiempo_key = tr.tiempo_key AND f.hora_key = tr.hora_key);

    SELECT @filas_omitidas = COUNT(*) FROM #trf WHERE ya_cargado = 1;

    /* L · Rechazos ----------------------------------------------------- */
    INSERT INTO dbo.etl_rechazo (ejecucion_id, medicion_id, motivo, detalle)
    SELECT @ejecucion_id, tr.medicion_id, tr.motivo,
           CONCAT(N'luminaria_id=', tr.luminaria_id, N'; fecha=', CONVERT(VARCHAR(19), tr.fecha_hora, 120),
                  N'; brillo=', ISNULL(CONVERT(NVARCHAR(12), tr.brillo_original), N'NULL'))
    FROM #trf tr
    WHERE tr.motivo IS NOT NULL AND tr.ya_cargado = 0;
    SET @rechazadas = @@ROWCOUNT;

    /* L · Hecho principal --------------------------------------------- */
    INSERT INTO dbo.fact_operacion_luminaria
        (medicion_id, tiempo_key, hora_key, luminaria_key, ubicacion_key, sensor_luz_key, sensor_presencia_key, estado_key,
         origen_key, calidad_key, es_noche, encendida, en_falla, es_anomala, nivel_luz_lux, detecciones, brillo_pct,
         tension_v, corriente_a, potencia_w, energia_wh, energia_referencia_wh, ahorro_wh, temperatura_c, ejecucion_id)
    SELECT
        tr.medicion_id, tr.tiempo_key, tr.hora_key, tr.luminaria_key, tr.ubicacion_key, tr.sensor_luz_key, tr.sensor_presencia_key,
        tr.estado_key, tr.origen_key, tr.calidad_key, tr.es_noche, tr.encendida, tr.en_falla, tr.es_anomala, tr.nivel_luz_lux,
        tr.detecciones, tr.brillo_pct, tr.tension_v, tr.corriente_a, tr.potencia_w, tr.energia_wh, tr.energia_referencia_wh,
        tr.ahorro_wh, tr.temperatura_c, @ejecucion_id
    FROM #trf tr
    WHERE tr.motivo IS NULL AND tr.ya_cargado = 0
    ORDER BY tr.medicion_id;
    SET @insertadas = @@ROWCOUNT;

    DECLARE @detalle NVARCHAR(400) = CONCAT(N'Leídas ', @filas_leidas, N' · insertadas ', @insertadas,
                                            N' · rechazadas ', @rechazadas, N' · omitidas ', @filas_omitidas);
    EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hecho de operación (T-SQL)', @t, @insertadas, 'OK', @detalle;
END
GO

/* ------------------------------------------------------------------
   Hecho de eventos en T-SQL. Aplica las MISMAS reglas que el flujo de
   datos DFT_Eventos de SSIS: validación, homologación de la acción,
   atributos derivados, búsqueda de claves y control de duplicados.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_cargar_eventos_tsql
    @ejecucion_id      INT,
    @eventos_leidos    INT = NULL OUTPUT,
    @eventos_omitidos  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    DECLARE @emin BIGINT, @emax BIGINT, @insertados INT, @rechazados INT;

    SELECT @emin = evento_watermark_inicial, @emax = evento_watermark_final
    FROM dbo.etl_ejecucion WHERE ejecucion_id = @ejecucion_id;

    /* E · Extracción ------------------------------------------------- */
    IF OBJECT_ID('tempdb..#eve') IS NOT NULL DROP TABLE #eve;
    SELECT x.* INTO #eve FROM src.fn_etl_extraccion_eventos(@emin, @emax) AS x;
    SET @eventos_leidos = @@ROWCOUNT;

    /* T · Validación, homologación, atributos y claves ---------------- */
    IF OBJECT_ID('tempdb..#evt') IS NOT NULL DROP TABLE #evt;
    SELECT
        e.evento_id, e.tipo_codigo, e.fecha_hora, e.brillo_nuevo, e.falla_id, e.mantenimiento_id, e.minutos_desde_anterior,
        v.motivo,
        h.accion_homologada,
        h.detalle_homologado,
        CAST(CASE WHEN e.brillo_anterior IS NULL OR e.brillo_nuevo IS NULL THEN NULL
                  ELSE e.brillo_nuevo - e.brillo_anterior END AS DECIMAL(6,1)) AS variacion_brillo_pct,
        CAST(CASE WHEN e.tipo_codigo IN (N'FALLA_DETECTADA', N'DESCONEXION') THEN 1 ELSE 0 END AS TINYINT) AS es_critico,
        dt.tiempo_key, dh.hora_key, dl.luminaria_key, du.ubicacion_key, dte.tipo_evento_key, dp.proceso_key,
        dus.usuario_key, dor.origen_key, dea.estado_key AS estado_anterior_key, den.estado_key AS estado_nuevo_key,
        CAST(0 AS TINYINT) AS ya_cargado
    INTO #evt
    FROM #eve e
    CROSS APPLY (SELECT CAST(CASE
            WHEN e.orden_duplicado > 1 THEN N'DUPLICADO'
            WHEN e.fecha_hora < '20260101' OR e.fecha_hora > DATEADD(DAY, 1, GETDATE()) THEN N'FECHA_INVALIDA'
            WHEN e.brillo_nuevo < 0 OR e.brillo_nuevo > 100 OR e.brillo_anterior < 0 OR e.brillo_anterior > 100 THEN N'BRILLO_FUERA_DE_RANGO'
        END AS NVARCHAR(40)) AS motivo) v
    CROSS APPLY (SELECT UPPER(ISNULL(e.detalle, N'')) AS det) d
    CROSS APPLY (SELECT
        CAST(CASE e.tipo_codigo
            WHEN N'ENCENDIDO'            THEN N'ENCENDIDO'
            WHEN N'APAGADO'              THEN N'APAGADO'
            WHEN N'MODO_AHORRO'          THEN N'AHORRO'
            WHEN N'CAMBIO_BRILLO'        THEN CASE
                 WHEN e.brillo_anterior IS NOT NULL AND e.brillo_nuevo IS NOT NULL
                      THEN CASE WHEN e.brillo_nuevo > e.brillo_anterior THEN N'SUBE_BRILLO'
                                WHEN e.brillo_nuevo < e.brillo_anterior THEN N'BAJA_BRILLO'
                                ELSE N'AJUSTE_BRILLO' END
                 WHEN CHARINDEX(N'-> PERSONA', d.det) > 0 THEN N'SUBE_BRILLO'
                 WHEN CHARINDEX(N'PERSONA ->', d.det) > 0 THEN N'BAJA_BRILLO'
                 ELSE N'AJUSTE_BRILLO' END
            WHEN N'DETECCION_MOVIMIENTO' THEN N'PRESENCIA'
            WHEN N'CAMBIO_LUZ_AMBIENTE'  THEN CASE WHEN CHARINDEX(N'DIA -> NOCHE', d.det) > 0 THEN N'ANOCHECER'
                                                   WHEN CHARINDEX(N'NOCHE -> DIA', d.det) > 0 THEN N'AMANECER'
                                                   ELSE N'CAMBIO_LUZ' END
            WHEN N'FALLA_DETECTADA'      THEN N'FALLA_INICIO'
            WHEN N'FALLA_RESUELTA'       THEN N'FALLA_FIN'
            WHEN N'INICIO_MANTENIMIENTO' THEN N'MANT_INICIO'
            WHEN N'FIN_MANTENIMIENTO'    THEN N'MANT_FIN'
            WHEN N'CONEXION'             THEN N'CONEXION'
            WHEN N'DESCONEXION'          THEN N'DESCONEXION'
            ELSE N'OTRO' END AS NVARCHAR(20)) AS accion_homologada,
        CAST(CASE WHEN LEN(LTRIM(RTRIM(ISNULL(e.detalle, N'')))) = 0 THEN N'Sin detalle'
                  ELSE LTRIM(RTRIM(e.detalle)) END AS NVARCHAR(200)) AS detalle_homologado) h
    LEFT JOIN dbo.dim_tiempo dt              ON dt.tiempo_key = e.tiempo_key AND dt.tiempo_key > 0
    LEFT JOIN dbo.dim_hora dh                ON dh.hora_key = e.hora_key
    LEFT JOIN dbo.dim_luminaria dl           ON dl.luminaria_id = e.luminaria_id
    LEFT JOIN dbo.dim_ubicacion du           ON du.ubicacion_id = e.ubicacion_id
    LEFT JOIN dbo.dim_tipo_evento dte        ON dte.tipo_evento_id = e.tipo_evento_id
    LEFT JOIN dbo.dim_proceso dp             ON dp.proceso_id = e.proceso_id
    LEFT JOIN dbo.dim_usuario dus            ON dus.usuario_id = e.usuario_id
    LEFT JOIN dbo.dim_origen dor             ON dor.origen_id = e.origen_id
    LEFT JOIN dbo.dim_estado_operativo dea   ON dea.estado_id = e.estado_anterior_id
    LEFT JOIN dbo.dim_estado_operativo den   ON den.estado_id = e.estado_nuevo_id;

    UPDATE #evt SET motivo = N'CLAVE_SIN_DIMENSION'
    WHERE motivo IS NULL
      AND (tiempo_key IS NULL OR hora_key IS NULL OR luminaria_key IS NULL OR ubicacion_key IS NULL OR tipo_evento_key IS NULL
           OR proceso_key IS NULL OR usuario_key IS NULL OR origen_key IS NULL OR estado_anterior_key IS NULL OR estado_nuevo_key IS NULL);

    /* Eventos que ya están en el hecho (re-ejecución): se omiten sin rechazarlos */
    UPDATE x SET ya_cargado = 1
    FROM #evt x
    WHERE EXISTS (SELECT 1 FROM dbo.fact_evento_operativo f WHERE f.evento_id = x.evento_id);

    SELECT @eventos_omitidos = COUNT(*) FROM #evt WHERE ya_cargado = 1;

    /* L · Rechazos ----------------------------------------------------- */
    INSERT INTO dbo.etl_rechazo (ejecucion_id, evento_id, motivo, detalle)
    SELECT @ejecucion_id, x.evento_id, x.motivo,
           CONCAT(N'tipo=', x.tipo_codigo, N'; fecha=', CONVERT(VARCHAR(19), x.fecha_hora, 120),
                  N'; brillo_nuevo=', ISNULL(CONVERT(NVARCHAR(12), x.brillo_nuevo), N'NULL'))
    FROM #evt x
    WHERE x.motivo IS NOT NULL AND x.ya_cargado = 0;
    SET @rechazados = @@ROWCOUNT;

    /* L · Hecho de eventos --------------------------------------------- */
    INSERT INTO dbo.fact_evento_operativo
        (evento_id, tiempo_key, hora_key, luminaria_key, ubicacion_key, tipo_evento_key, proceso_key, usuario_key, origen_key,
         estado_anterior_key, estado_nuevo_key, fecha_hora, accion_homologada, detalle, falla_id, mantenimiento_id,
         cantidad_eventos, es_critico, variacion_brillo_pct, minutos_desde_anterior, ejecucion_id)
    SELECT x.evento_id, x.tiempo_key, x.hora_key, x.luminaria_key, x.ubicacion_key, x.tipo_evento_key, x.proceso_key, x.usuario_key,
           x.origen_key, x.estado_anterior_key, x.estado_nuevo_key, x.fecha_hora, x.accion_homologada, x.detalle_homologado,
           x.falla_id, x.mantenimiento_id, 1, x.es_critico, x.variacion_brillo_pct, x.minutos_desde_anterior, @ejecucion_id
    FROM #evt x
    WHERE x.motivo IS NULL AND x.ya_cargado = 0
    ORDER BY x.evento_id;
    SET @insertados = @@ROWCOUNT;

    DECLARE @detalle NVARCHAR(400) = CONCAT(N'Leídos ', @eventos_leidos, N' · insertados ', @insertados,
                                            N' · rechazados ', @rechazados, N' · omitidos ', @eventos_omitidos);
    EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hecho de eventos (T-SQL)', @t, @insertados, 'OK', @detalle;
END
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_cargar_hechos_secundarios
    @ejecucion_id INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    DECLARE @filas INT = 0;
    DECLARE @corte DATETIME2(0) = (SELECT MAX(fecha_hora) FROM src.medicion WHERE origen_id IN (1, 2));
    IF @corte IS NULL SET @corte = SYSDATETIME();

    /* fact_falla ------------------------------------------------------- */
    MERGE dbo.fact_falla AS t
    USING (
        SELECT
            f.falla_id,
            CAST(CONVERT(CHAR(8), f.fecha_deteccion, 112) AS INT) AS tiempo_deteccion_key,
            CAST(DATEPART(HOUR, f.fecha_deteccion) * 100 + (DATEPART(MINUTE, f.fecha_deteccion) / 15) * 15 AS SMALLINT) AS hora_deteccion_key,
            CASE WHEN f.fecha_resolucion IS NULL THEN 0 ELSE CAST(CONVERT(CHAR(8), f.fecha_resolucion, 112) AS INT) END AS tiempo_resolucion_key,
            dl.luminaria_key,
            du.ubicacion_key,
            dtf.tipo_falla_key,
            ISNULL(ds.sensor_key, 0) AS sensor_key,
            dor.origen_key,
            CAST(CASE WHEN f.fecha_resolucion IS NULL THEN 1 ELSE 0 END AS TINYINT) AS esta_abierta,
            CAST(DATEDIFF(MINUTE, f.fecha_inicio, f.fecha_deteccion) / 60.0 AS DECIMAL(8,2)) AS horas_hasta_deteccion,
            CAST(CASE WHEN DATEDIFF(MINUTE, f.fecha_inicio, ISNULL(f.fecha_resolucion, @corte)) < 0 THEN 0
                      ELSE DATEDIFF(MINUTE, f.fecha_inicio, ISNULL(f.fecha_resolucion, @corte)) END / 60.0 AS DECIMAL(9,2)) AS horas_duracion,
            CAST(CASE WHEN mt.n > 0 THEN 1 ELSE 0 END AS TINYINT) AS tiene_mantenimiento,
            mt.costo AS costo_correctivo_cop
        FROM src.falla f
        JOIN src.luminaria l ON l.luminaria_id = f.luminaria_id
        JOIN dbo.dim_luminaria dl ON dl.luminaria_id = f.luminaria_id
        JOIN dbo.dim_ubicacion du ON du.ubicacion_id = l.ubicacion_id
        JOIN dbo.dim_tipo_falla dtf ON dtf.tipo_falla_id = f.tipo_falla_id
        JOIN dbo.dim_origen dor ON dor.origen_id = f.origen_id
        LEFT JOIN dbo.dim_sensor ds ON ds.sensor_id = f.sensor_id
        OUTER APPLY (SELECT COUNT(*) AS n,
                            CAST(SUM(CASE WHEN m.estado = 'REALIZADO' THEN m.costo_cop END) AS DECIMAL(12,2)) AS costo
                     FROM src.mantenimiento m WHERE m.falla_id = f.falla_id) mt
    ) AS s
    ON t.falla_id = s.falla_id
    WHEN MATCHED AND EXISTS (
        SELECT s.tiempo_deteccion_key, s.hora_deteccion_key, s.tiempo_resolucion_key, s.luminaria_key, s.ubicacion_key, s.tipo_falla_key,
               s.sensor_key, s.origen_key, s.esta_abierta, s.horas_hasta_deteccion, s.horas_duracion, s.tiene_mantenimiento, s.costo_correctivo_cop
        EXCEPT
        SELECT t.tiempo_deteccion_key, t.hora_deteccion_key, t.tiempo_resolucion_key, t.luminaria_key, t.ubicacion_key, t.tipo_falla_key,
               t.sensor_key, t.origen_key, t.esta_abierta, t.horas_hasta_deteccion, t.horas_duracion, t.tiene_mantenimiento, t.costo_correctivo_cop)
        THEN UPDATE SET tiempo_deteccion_key = s.tiempo_deteccion_key, hora_deteccion_key = s.hora_deteccion_key,
                        tiempo_resolucion_key = s.tiempo_resolucion_key, luminaria_key = s.luminaria_key, ubicacion_key = s.ubicacion_key,
                        tipo_falla_key = s.tipo_falla_key, sensor_key = s.sensor_key, origen_key = s.origen_key,
                        esta_abierta = s.esta_abierta, horas_hasta_deteccion = s.horas_hasta_deteccion, horas_duracion = s.horas_duracion,
                        tiene_mantenimiento = s.tiene_mantenimiento, costo_correctivo_cop = s.costo_correctivo_cop,
                        ejecucion_id = @ejecucion_id, fecha_carga = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (falla_id, tiempo_deteccion_key, hora_deteccion_key, tiempo_resolucion_key, luminaria_key, ubicacion_key, tipo_falla_key,
                     sensor_key, origen_key, esta_abierta, horas_hasta_deteccion, horas_duracion, tiene_mantenimiento, costo_correctivo_cop, ejecucion_id)
             VALUES (s.falla_id, s.tiempo_deteccion_key, s.hora_deteccion_key, s.tiempo_resolucion_key, s.luminaria_key, s.ubicacion_key,
                     s.tipo_falla_key, s.sensor_key, s.origen_key, s.esta_abierta, s.horas_hasta_deteccion, s.horas_duracion,
                     s.tiene_mantenimiento, s.costo_correctivo_cop, @ejecucion_id)
    WHEN NOT MATCHED BY SOURCE
        THEN DELETE;
    SET @filas += @@ROWCOUNT;

    /* fact_mantenimiento ---------------------------------------------- */
    MERGE dbo.fact_mantenimiento AS t
    USING (
        SELECT
            m.mantenimiento_id,
            CAST(CONVERT(CHAR(8), m.fecha_programada, 112) AS INT) AS tiempo_programado_key,
            CASE WHEN m.fecha_inicio IS NULL THEN 0 ELSE CAST(CONVERT(CHAR(8), m.fecha_inicio, 112) AS INT) END AS tiempo_ejecucion_key,
            dl.luminaria_key,
            du.ubicacion_key,
            dtm.tipo_mantenimiento_key,
            ISNULL(dte.tecnico_key, 0) AS tecnico_key,
            dor.origen_key,
            m.falla_id,
            m.estado,
            CAST(CASE WHEN m.estado IN ('PROGRAMADO', 'EN_PROCESO') THEN 1 ELSE 0 END AS TINYINT) AS es_pendiente,
            CAST(tm.es_correctivo AS TINYINT) AS es_correctivo,
            CASE WHEN m.fecha_inicio IS NOT NULL AND m.fecha_fin IS NOT NULL THEN DATEDIFF(MINUTE, m.fecha_inicio, m.fecha_fin) END AS duracion_min,
            m.costo_cop,
            CASE WHEN m.fecha_inicio IS NOT NULL THEN CAST(DATEDIFF(MINUTE, m.fecha_programada, m.fecha_inicio) / 1440.0 AS DECIMAL(7,2)) END AS dias_retraso
        FROM src.mantenimiento m
        JOIN src.luminaria l ON l.luminaria_id = m.luminaria_id
        JOIN src.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = m.tipo_mantenimiento_id
        JOIN dbo.dim_luminaria dl ON dl.luminaria_id = m.luminaria_id
        JOIN dbo.dim_ubicacion du ON du.ubicacion_id = l.ubicacion_id
        JOIN dbo.dim_tipo_mantenimiento dtm ON dtm.tipo_mantenimiento_id = m.tipo_mantenimiento_id
        JOIN dbo.dim_origen dor ON dor.origen_id = m.origen_id
        LEFT JOIN dbo.dim_tecnico dte ON dte.tecnico_id = m.tecnico_id
    ) AS s
    ON t.mantenimiento_id = s.mantenimiento_id
    WHEN MATCHED AND EXISTS (
        SELECT s.tiempo_programado_key, s.tiempo_ejecucion_key, s.luminaria_key, s.ubicacion_key, s.tipo_mantenimiento_key, s.tecnico_key,
               s.origen_key, s.falla_id, s.estado, s.es_pendiente, s.es_correctivo, s.duracion_min, s.costo_cop, s.dias_retraso
        EXCEPT
        SELECT t.tiempo_programado_key, t.tiempo_ejecucion_key, t.luminaria_key, t.ubicacion_key, t.tipo_mantenimiento_key, t.tecnico_key,
               t.origen_key, t.falla_id, t.estado, t.es_pendiente, t.es_correctivo, t.duracion_min, t.costo_cop, t.dias_retraso)
        THEN UPDATE SET tiempo_programado_key = s.tiempo_programado_key, tiempo_ejecucion_key = s.tiempo_ejecucion_key,
                        luminaria_key = s.luminaria_key, ubicacion_key = s.ubicacion_key, tipo_mantenimiento_key = s.tipo_mantenimiento_key,
                        tecnico_key = s.tecnico_key, origen_key = s.origen_key, falla_id = s.falla_id, estado = s.estado,
                        es_pendiente = s.es_pendiente, es_correctivo = s.es_correctivo, duracion_min = s.duracion_min,
                        costo_cop = s.costo_cop, dias_retraso = s.dias_retraso, ejecucion_id = @ejecucion_id, fecha_carga = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (mantenimiento_id, tiempo_programado_key, tiempo_ejecucion_key, luminaria_key, ubicacion_key, tipo_mantenimiento_key,
                     tecnico_key, origen_key, falla_id, estado, es_pendiente, es_correctivo, duracion_min, costo_cop, dias_retraso, ejecucion_id)
             VALUES (s.mantenimiento_id, s.tiempo_programado_key, s.tiempo_ejecucion_key, s.luminaria_key, s.ubicacion_key,
                     s.tipo_mantenimiento_key, s.tecnico_key, s.origen_key, s.falla_id, s.estado, s.es_pendiente, s.es_correctivo,
                     s.duracion_min, s.costo_cop, s.dias_retraso, @ejecucion_id)
    WHEN NOT MATCHED BY SOURCE
        THEN DELETE;
    SET @filas += @@ROWCOUNT;

    EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hechos de fallas y mantenimiento', @t, @filas, 'OK', NULL;
END
GO

/* ------------------------------------------------------------------
   Hechos agregados: se recalculan solo los días afectados
   (por una ejecución, o por un rango de tiempo_key)
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_actualizar_agregados
    @ejecucion_id     INT = NULL,
    @tiempo_key_desde INT = NULL,
    @tiempo_key_hasta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(0) = SYSDATETIME();
    DECLARE @filas INT = 0;

    IF OBJECT_ID('tempdb..#dias') IS NOT NULL DROP TABLE #dias;
    CREATE TABLE #dias (tiempo_key INT NOT NULL PRIMARY KEY);

    IF @tiempo_key_desde IS NOT NULL
        INSERT INTO #dias (tiempo_key)
        SELECT tiempo_key FROM dbo.dim_tiempo WHERE tiempo_key BETWEEN @tiempo_key_desde AND ISNULL(@tiempo_key_hasta, @tiempo_key_desde) AND tiempo_key > 0;
    ELSE
        INSERT INTO #dias (tiempo_key)
        SELECT DISTINCT tiempo_key FROM dbo.fact_operacion_luminaria WHERE ejecucion_id = @ejecucion_id;

    DELETE c FROM dbo.fact_consumo_diario c JOIN #dias d ON d.tiempo_key = c.tiempo_key;

    INSERT INTO dbo.fact_consumo_diario
        (tiempo_key, luminaria_key, ubicacion_key, origen_key, intervalos, intervalos_encendida, intervalos_falla, intervalos_anomalos,
         intervalos_imputados, detecciones, horas_encendida, brillo_promedio_noche, energia_kwh, energia_referencia_kwh, ahorro_kwh)
    SELECT
        f.tiempo_key,
        f.luminaria_key,
        MIN(f.ubicacion_key),
        f.origen_key,
        COUNT(*),
        SUM(CAST(f.encendida AS INT)),
        SUM(CAST(f.en_falla AS INT)),
        SUM(CAST(f.es_anomala AS INT)),
        SUM(CASE WHEN f.calidad_key IN (2, 4) THEN 1 ELSE 0 END),
        SUM(CAST(f.detecciones AS INT)),
        CAST(SUM(CAST(f.encendida AS INT)) * 0.25 AS DECIMAL(6,2)),
        CAST(ISNULL(AVG(CASE WHEN f.es_noche = 1 THEN f.brillo_pct END), 0) AS DECIMAL(5,1)),
        CAST(SUM(f.energia_wh) / 1000.0 AS DECIMAL(12,4)),
        CAST(SUM(f.energia_referencia_wh) / 1000.0 AS DECIMAL(12,4)),
        CAST(SUM(f.ahorro_wh) / 1000.0 AS DECIMAL(12,4))
    FROM dbo.fact_operacion_luminaria f
    JOIN #dias d ON d.tiempo_key = f.tiempo_key
    GROUP BY f.tiempo_key, f.luminaria_key, f.origen_key;
    SET @filas += @@ROWCOUNT;

    DELETE h FROM dbo.fact_operacion_horaria h JOIN #dias d ON d.tiempo_key = h.tiempo_key;

    INSERT INTO dbo.fact_operacion_horaria
        (tiempo_key, hora_key, ubicacion_key, estado_key, origen_key, intervalos, intervalos_encendida, detecciones,
         suma_brillo, suma_lux, energia_wh, energia_referencia_wh)
    SELECT
        f.tiempo_key, f.hora_key, f.ubicacion_key, f.estado_key, f.origen_key,
        COUNT(*),
        SUM(CAST(f.encendida AS INT)),
        SUM(CAST(f.detecciones AS INT)),
        CAST(SUM(f.brillo_pct) AS DECIMAL(12,1)),
        CAST(SUM(f.nivel_luz_lux) AS DECIMAL(16,1)),
        CAST(SUM(f.energia_wh) AS DECIMAL(14,3)),
        CAST(SUM(f.energia_referencia_wh) AS DECIMAL(14,3))
    FROM dbo.fact_operacion_luminaria f
    JOIN #dias d ON d.tiempo_key = f.tiempo_key
    GROUP BY f.tiempo_key, f.hora_key, f.ubicacion_key, f.estado_key, f.origen_key;
    SET @filas += @@ROWCOUNT;

    IF @ejecucion_id IS NOT NULL
        EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hechos agregados (diario y horario)', @t, @filas, 'OK', NULL;
END
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_finalizar
    @ejecucion_id      INT,
    @filas_leidas      INT = NULL,
    @filas_omitidas    INT = NULL,
    @eventos_leidos    INT = NULL,
    @eventos_omitidos  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ins INT, @rech INT, @imp INT, @anom INT, @herr VARCHAR(10), @inicio DATETIME2(0);
    DECLARE @ev_ins INT, @ev_rech INT;

    SELECT @ins = COUNT(*),
           @imp = SUM(CASE WHEN calidad_key IN (2, 4) THEN 1 ELSE 0 END),
           @anom = SUM(CASE WHEN calidad_key IN (3, 4) THEN 1 ELSE 0 END)
    FROM dbo.fact_operacion_luminaria WHERE ejecucion_id = @ejecucion_id;
    SELECT @rech = COUNT(*) FROM dbo.etl_rechazo WHERE ejecucion_id = @ejecucion_id AND medicion_id IS NOT NULL;
    SELECT @ev_ins = COUNT(*) FROM dbo.fact_evento_operativo WHERE ejecucion_id = @ejecucion_id;
    SELECT @ev_rech = COUNT(*) FROM dbo.etl_rechazo WHERE ejecucion_id = @ejecucion_id AND evento_id IS NOT NULL;
    SELECT @herr = herramienta, @inicio = inicio FROM dbo.etl_ejecucion WHERE ejecucion_id = @ejecucion_id;

    SET @imp = ISNULL(@imp, 0);
    SET @anom = ISNULL(@anom, 0);
    SET @filas_omitidas = ISNULL(@filas_omitidas, 0);
    SET @filas_leidas = ISNULL(@filas_leidas, @ins + @rech + @filas_omitidas);
    SET @eventos_omitidos = ISNULL(@eventos_omitidos, 0);
    SET @eventos_leidos = ISNULL(@eventos_leidos, @ev_ins + @ev_rech + @eventos_omitidos);

    IF @herr = 'SSIS'
    BEGIN
        EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hecho de operación (flujo de datos SSIS)', @inicio, @ins, 'OK', NULL;
        DECLARE @det_ev NVARCHAR(400) = CONCAT(N'Leídos ', @eventos_leidos, N' · insertados ', @ev_ins,
                                               N' · rechazados ', @ev_rech, N' · omitidos ', @eventos_omitidos);
        EXEC dbo.sp_etl_registrar_paso @ejecucion_id, N'Hecho de eventos (flujo de datos SSIS)', @inicio, @ev_ins, 'OK', @det_ev;
    END

    UPDATE dbo.etl_ejecucion
       SET fin = SYSDATETIME(),
           estado = CASE WHEN @rech + @ev_rech > 0 THEN 'CON_RECHAZOS' ELSE 'EXITOSA' END,
           filas_leidas = @filas_leidas,
           filas_insertadas = @ins,
           filas_rechazadas = @rech,
           filas_omitidas = @filas_omitidas,
           filas_imputadas = @imp,
           filas_anomalas = @anom,
           eventos_leidos = @eventos_leidos,
           eventos_insertados = @ev_ins,
           eventos_rechazados = @ev_rech,
           eventos_omitidos = @eventos_omitidos,
           mensaje = CONCAT(N'Mediciones: leídas ', @filas_leidas, N' · insertadas ', @ins, N' · rechazadas ', @rech,
                            N' · omitidas ', @filas_omitidas, N' · imputadas ', @imp, N' · anómalas ', @anom,
                            N' | Eventos: leídos ', @eventos_leidos, N' · insertados ', @ev_ins,
                            N' · rechazados ', @ev_rech, N' · omitidos ', @eventos_omitidos)
     WHERE ejecucion_id = @ejecucion_id;

    UPDATE c
       SET ultimo_medicion_id = CASE c.proceso WHEN 'FACT_OPERACION' THEN e.watermark_final ELSE e.evento_watermark_final END,
           ultima_ejecucion_id = e.ejecucion_id, actualizado = SYSDATETIME()
      FROM dbo.etl_control c
      JOIN dbo.etl_ejecucion e ON e.ejecucion_id = @ejecucion_id
     WHERE c.proceso IN ('FACT_OPERACION', 'FACT_EVENTO');

    SELECT ejecucion_id, herramienta, estado, inicio, fin, filas_leidas, filas_insertadas, filas_rechazadas,
           filas_omitidas, filas_imputadas, filas_anomalas, eventos_leidos, eventos_insertados, eventos_rechazados,
           eventos_omitidos, dimensiones_actualizadas, mensaje
    FROM dbo.etl_ejecucion WHERE ejecucion_id = @ejecucion_id;
END
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_registrar_error
    @ejecucion_id INT,
    @mensaje      NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;
    IF @ejecucion_id IS NULL OR @ejecucion_id = 0
        SELECT @ejecucion_id = MAX(ejecucion_id) FROM dbo.etl_ejecucion WHERE estado = 'EN_CURSO';
    IF @ejecucion_id IS NULL RETURN;

    UPDATE dbo.etl_ejecucion
       SET estado = 'FALLIDA',
           fin = SYSDATETIME(),
           mensaje = LEFT(CONCAT(ISNULL(mensaje + N' | ', N''), @mensaje), 4000)
     WHERE ejecucion_id = @ejecucion_id;

    INSERT INTO dbo.etl_paso (ejecucion_id, paso, inicio, fin, filas, estado, mensaje)
    VALUES (@ejecucion_id, N'Error', SYSDATETIME(), SYSDATETIME(), NULL, 'ERROR', LEFT(@mensaje, 2000));
END
GO

/* ------------------------------------------------------------------
   Orquestador del ETL en T-SQL (alternativa a SSIS)
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_ejecutar_tsql
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT, @wmin INT, @wmax INT, @emin INT, @emax INT, @dims INT, @leidas INT, @omitidas INT,
            @ev_leidos INT, @ev_omitidos INT;

    EXEC dbo.sp_etl_iniciar @herramienta = 'TSQL', @paquete = N'sp_etl_ejecutar_tsql',
         @ejecucion_id = @id OUTPUT, @watermark_min = @wmin OUTPUT, @watermark_max = @wmax OUTPUT,
         @evento_min = @emin OUTPUT, @evento_max = @emax OUTPUT;

    BEGIN TRY
        RAISERROR(N'1/5 Dimensiones...', 0, 1) WITH NOWAIT;
        EXEC dbo.sp_etl_cargar_dimensiones @ejecucion_id = @id, @filas_afectadas = @dims OUTPUT;

        RAISERROR(N'2/5 Hecho de operación (puede tardar algunos minutos la primera vez)...', 0, 1) WITH NOWAIT;
        EXEC dbo.sp_etl_cargar_hechos_tsql @ejecucion_id = @id, @filas_leidas = @leidas OUTPUT, @filas_omitidas = @omitidas OUTPUT;

        RAISERROR(N'3/5 Hecho de eventos...', 0, 1) WITH NOWAIT;
        EXEC dbo.sp_etl_cargar_eventos_tsql @ejecucion_id = @id, @eventos_leidos = @ev_leidos OUTPUT, @eventos_omitidos = @ev_omitidos OUTPUT;

        RAISERROR(N'4/5 Hechos de fallas y mantenimiento...', 0, 1) WITH NOWAIT;
        EXEC dbo.sp_etl_cargar_hechos_secundarios @ejecucion_id = @id;

        RAISERROR(N'5/5 Hechos agregados...', 0, 1) WITH NOWAIT;
        EXEC dbo.sp_etl_actualizar_agregados @ejecucion_id = @id;

        EXEC dbo.sp_etl_finalizar @ejecucion_id = @id, @filas_leidas = @leidas, @filas_omitidas = @omitidas,
             @eventos_leidos = @ev_leidos, @eventos_omitidos = @ev_omitidos;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(4000) = CONCAT(ERROR_MESSAGE(), N' (procedimiento ', ISNULL(ERROR_PROCEDURE(), N'-'),
                                             N', línea ', ERROR_LINE(), N')');
        EXEC dbo.sp_etl_registrar_error @ejecucion_id = @id, @mensaje = @err;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------
   Reinicio: vacía los hechos para repetir la carga completa.
   @borrar_historial = 1 también borra el historial del ETL.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_etl_reiniciar
    @borrar_historial BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.fact_operacion_luminaria;
    TRUNCATE TABLE dbo.fact_consumo_diario;
    TRUNCATE TABLE dbo.fact_operacion_horaria;
    TRUNCATE TABLE dbo.fact_falla;
    TRUNCATE TABLE dbo.fact_mantenimiento;
    TRUNCATE TABLE dbo.fact_evento_operativo;
    UPDATE dbo.etl_control SET ultimo_medicion_id = 0, ultima_ejecucion_id = NULL, actualizado = SYSDATETIME();   -- mediciones y eventos
    IF @borrar_historial = 1
    BEGIN
        DELETE FROM dbo.etl_rechazo;
        DELETE FROM dbo.etl_paso;
        DELETE FROM dbo.etl_ejecucion;
        DBCC CHECKIDENT ('dbo.etl_ejecucion', RESEED, 0) WITH NO_INFOMSGS;
    END
    PRINT N'Hechos vacíos. Ya puede volver a ejecutar el ETL desde cero.';
END
GO

PRINT N'Procedimientos del ETL creados. Para la carga completa sin SSIS: EXEC dbo.sp_etl_ejecutar_tsql;';
GO
