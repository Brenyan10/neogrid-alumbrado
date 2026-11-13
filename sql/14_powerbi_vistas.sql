/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   14_powerbi_vistas.sql
   Vistas de solo lectura en el esquema [pbi] de NeoGridDW para conectar
   Power BI Desktop (modo Importar). No modifica tablas ni datos: solo
   expone las columnas que usa el dashboard, con nombres legibles.

   Las filas de origen PRUEBA (insertadas a propósito en la prueba de
   rechazos, ejecución 1020: 3 mediciones y 2 eventos) se excluyen.

   Uso: abrir en SSMS conectado a la instancia local y ejecutar TODO (F5).
   Se puede ejecutar varias veces (CREATE OR ALTER).
   ===================================================================== */
USE NeoGridDW;
GO
IF SCHEMA_ID('pbi') IS NULL EXEC('CREATE SCHEMA pbi AUTHORIZATION dbo');
GO

/* ---------- Dimensiones ---------- */
CREATE OR ALTER VIEW pbi.dim_fecha AS
SELECT tiempo_key, fecha, anio, mes, nombre_mes, anio_mes, semana_anio, dia_mes,
       dia_semana, nombre_dia,
       CASE WHEN es_festivo = 1 THEN N'Festivo'
            WHEN es_fin_semana = 1 THEN N'Fin de semana'
            ELSE N'Laboral' END AS tipo_dia
FROM dbo.dim_tiempo
WHERE tiempo_key <> 0;
GO

CREATE OR ALTER VIEW pbi.dim_hora AS
SELECT hora_key, hora, minuto, etiqueta, franja,
       CASE franja WHEN N'Noche' THEN 1 WHEN N'Madrugada' THEN 2
                   WHEN N'Mañana' THEN 3 ELSE 4 END AS orden_franja,
       es_horario_nocturno
FROM dbo.dim_hora;
GO

CREATE OR ALTER VIEW pbi.dim_luminaria AS
SELECT luminaria_key, codigo AS luminaria, modelo_codigo AS modelo, tecnologia,
       potencia_nominal_w, CASE es_fisica WHEN 1 THEN N'Física (maqueta)' ELSE N'Solo simulada' END AS tipo_luminaria,
       tablero
FROM dbo.dim_luminaria;
GO

CREATE OR ALTER VIEW pbi.dim_ubicacion AS
SELECT ubicacion_key, codigo AS ubicacion, nombre AS calle, tipo_via,
       zona_codigo, zona_nombre AS zona, tipo_zona
FROM dbo.dim_ubicacion;
GO

CREATE OR ALTER VIEW pbi.dim_origen AS
SELECT origen_key, codigo AS origen, nombre AS origen_nombre
FROM dbo.dim_origen
WHERE codigo <> 'PRUEBA';
GO

CREATE OR ALTER VIEW pbi.dim_calidad AS
SELECT calidad_key, codigo AS calidad, descripcion AS calidad_descripcion, fue_imputado, es_anomalo
FROM dbo.dim_calidad_dato;
GO

CREATE OR ALTER VIEW pbi.dim_tipo_falla AS
SELECT tipo_falla_key, codigo AS tipo_falla, nombre AS tipo_falla_nombre, severidad
FROM dbo.dim_tipo_falla;
GO

CREATE OR ALTER VIEW pbi.dim_proceso AS
SELECT proceso_key, codigo AS proceso_codigo, nombre AS proceso, tipo_operacion,
       CASE es_automatico WHEN 1 THEN N'Automático' ELSE N'Manual' END AS modo,
       responsable_nombre AS responsable
FROM dbo.dim_proceso;
GO

CREATE OR ALTER VIEW pbi.dim_usuario AS
SELECT usuario_key, nombre AS usuario, rol_nombre AS rol,
       CASE es_automatico WHEN 1 THEN N'Sistema' ELSE N'Persona' END AS tipo_actor
FROM dbo.dim_usuario;
GO

CREATE OR ALTER VIEW pbi.dim_tipo_evento AS
SELECT tipo_evento_key, codigo AS tipo_evento, nombre AS tipo_evento_nombre, categoria AS categoria_evento
FROM dbo.dim_tipo_evento;
GO

/* ---------- Hechos ---------- */
-- Grano: una luminaria en un intervalo de 15 minutos (1.000.320 filas)
CREATE OR ALTER VIEW pbi.fact_operacion AS
-- Sin fact_id ni columnas que el dashboard no usa: cada columna con muchos valores
-- distintos aumenta mucho la memoria que Power BI necesita para un millón de filas.
SELECT f.tiempo_key, f.hora_key, f.luminaria_key, f.ubicacion_key, f.origen_key, f.calidad_key,
       f.es_noche, f.encendida, f.en_falla,
       f.detecciones, f.brillo_pct,
       f.energia_wh, f.energia_referencia_wh, f.ahorro_wh,
       CASE WHEN f.es_noche = 0 AND f.encendida = 1 THEN 1 ELSE 0 END AS encendida_de_dia
FROM dbo.fact_operacion_luminaria f
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo <> 'PRUEBA';   -- excluye las filas de la prueba de rechazos (ejecución 1020)
GO

-- Grano: una falla
CREATE OR ALTER VIEW pbi.fact_falla AS
SELECT f.falla_id, f.tiempo_deteccion_key AS tiempo_key, f.hora_deteccion_key AS hora_key,
       f.luminaria_key, f.ubicacion_key, f.tipo_falla_key, f.origen_key,
       f.esta_abierta, f.horas_hasta_deteccion, f.horas_duracion, f.tiene_mantenimiento,
       f.costo_correctivo_cop
FROM dbo.fact_falla f
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo <> 'PRUEBA';
GO

-- Grano: un evento operativo
CREATE OR ALTER VIEW pbi.fact_evento AS
SELECT f.tiempo_key, f.hora_key, f.luminaria_key, f.ubicacion_key,
       f.tipo_evento_key, f.proceso_key, f.usuario_key, f.origen_key,
       f.accion_homologada, f.cantidad_eventos, f.es_critico, f.variacion_brillo_pct
FROM dbo.fact_evento_operativo f
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo <> 'PRUEBA';
GO

/* ---------- Comprobación ---------- */
SELECT 'pbi.fact_operacion' AS vista, COUNT_BIG(*) AS filas FROM pbi.fact_operacion
UNION ALL SELECT 'pbi.fact_falla', COUNT_BIG(*) FROM pbi.fact_falla
UNION ALL SELECT 'pbi.fact_evento', COUNT_BIG(*) FROM pbi.fact_evento
UNION ALL SELECT 'pbi.dim_fecha', COUNT_BIG(*) FROM pbi.dim_fecha
UNION ALL SELECT 'pbi.dim_hora', COUNT_BIG(*) FROM pbi.dim_hora
UNION ALL SELECT 'pbi.dim_luminaria', COUNT_BIG(*) FROM pbi.dim_luminaria
UNION ALL SELECT 'pbi.dim_ubicacion', COUNT_BIG(*) FROM pbi.dim_ubicacion;
GO
