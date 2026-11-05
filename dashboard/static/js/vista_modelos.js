/* NeoGrid · vistas de los modelos de datos: relacional, multidimensional, monitor ETL y comparación. */
(function () {
  "use strict";
  const NG = window.NG;
  NG.vistas = NG.vistas || {};
  const CAT = { CATALOGO: "Catálogo", MAESTRA: "Maestra", TRANSACCIONAL: "Transaccional", CALCULADA: "Calculada", CONTROL: "Control",
    DIMENSION: "Dimensión", HECHO: "Hecho", HECHO_AGREGADO: "Hecho agregado", ETL: "Control del ETL" };

  function tablaTablas(lista, modelo) {
    return NG.tabla([
      { clave: "tabla", titulo: "Tabla", nodo: (v) => NG.el("a", { href: "#/explorador?modelo=" + modelo + "&tabla=" + encodeURIComponent(v), texto: v }) },
      { clave: "categoria", titulo: "Categoría", formato: (v) => CAT[v] || v },
      { clave: "filas", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) },
      { clave: "columnas", titulo: "Columnas", num: true },
      { clave: "descripcion", titulo: "Descripción", formato: (v) => v || "" },
    ], lista, { alta: true });
  }

  function navegadorPaginado(panel, ruta, controles, columnas) {
    const estado = { pagina: 1 };
    const cont = NG.el("div");
    const sql = NG.el("pre", { clase: "sql codigo", hidden: true });
    const bs = NG.el("button", { type: "button", "aria-pressed": "false" }, "SQL");
    bs.addEventListener("click", () => { sql.hidden = !sql.hidden; bs.setAttribute("aria-pressed", String(!sql.hidden)); });
    panel.acciones.append(bs);
    const fila = NG.el("div", { clase: "filtro-fila" }, controles.map((x) => x.nodo));
    panel.cuerpo.append(fila, cont, sql);
    async function cargar() {
      cont.classList.add("recargando");
      const params = { pagina: estado.pagina, tam: 25 };
      controles.forEach((x) => { const v = x.valor(); if (v) params[x.nombre] = v; });
      try {
        const d = await NG.api(ruta, params, { signal: undefined });
        NG.vaciar(cont);
        cont.append(NG.tabla(columnas, d.filas, { textoNulo: "NULL" }), NG.paginador(d.pagina, d.tam, d.total, (p) => { estado.pagina = p; cargar(); }));
        sql.textContent = d.sql;
      } catch (e) { NG.vaciar(cont); cont.append(NG.aviso(e.message, true)); }
      cont.classList.remove("recargando");
    }
    controles.forEach((x) => x.nodo.addEventListener("change", () => { estado.pagina = 1; cargar(); }));
    cargar();
  }

  function selector(etiqueta, nombre, opciones, valor) {
    const s = NG.el("select", { "aria-label": etiqueta }, opciones.map(([v, t]) => NG.el("option", { value: v, selected: String(v) === String(valor || "") }, t)));
    return { nombre, nodo: NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: etiqueta }), s), valor: () => s.value, sel: s };
  }
  function fecha(etiqueta, nombre, valor) {
    const i = NG.el("input", { type: "date", value: valor || "", "aria-label": etiqueta });
    return { nombre, nodo: NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: etiqueta }), i), valor: () => i.value };
  }

  // ================================================================== relacional
  NG.vistas.relacional = {
    titulo: "Modelo relacional",
    sinFiltros: true,
    async render(c) {
      c.append(NG.encabezado("Modelo relacional · NeoGridRelacional", "Base operacional normalizada (tercera forma normal): cada hecho del mundo se guarda una sola vez y las tablas se unen por claves primarias y foráneas. Es el origen del ETL."));
      const [d, est] = await Promise.all([NG.api("relacional/resumen"), NG.api("explorar/relacional/tablas")]);
      const porOrigen = Object.fromEntries(d.mediciones_por_origen.map((o) => [o.codigo, o.n]));
      c.append(NG.cifras([
        { etiqueta: "Tablas", valor: NG.fmt.num(est.totales.tablas), nota: "Catálogos, maestras, transaccionales, calculadas y de control" },
        { etiqueta: "Filas en total", valor: NG.fmt.compacto(est.totales.filas) },
        { etiqueta: "Claves foráneas", valor: NG.fmt.num(d.relaciones), nota: NG.fmt.num(d.indices) + " índices" },
        { etiqueta: "Mediciones simuladas", valor: NG.fmt.num(porOrigen.SIMULADO || 0), nota: "Tabla principal medicion" },
        { etiqueta: "Mediciones físicas", valor: NG.fmt.num(porOrigen.FISICO || 0), nota: "Llegadas de la maqueta por MQTT" },
      ]));
      const pT = NG.panel({ titulo: "Tablas del modelo", subtitulo: "Haga clic en una tabla para ver sus columnas, claves, índices y datos en el explorador." });
      pT.acciones.append(NG.el("button", { type: "button", onclick: () => { location.hash = "#/explorador?modelo=relacional&pestana=diagrama"; } }, "Diagrama entidad-relación"));
      c.append(pT.raiz);
      pT.cuerpo.append(tablaTablas(d.tablas, "relacional"));

      const r = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r);
      const pO = NG.panel({ titulo: "Mediciones por origen", subtitulo: "Agrupación sobre la tabla principal con el índice IX_medicion_origen." });
      r.append(pO.raiz);
      const COL = { FISICO: "--s2", SIMULADO: "--s1", CALCULADO: "--s3", PRUEBA: "--s4" };
      NG.graf.tarjeta(pO, (g) => NG.graf.segmentada(g, { partes: d.mediciones_por_origen.map((o) => ({ nombre: o.nombre, valor: o.n, color: COL[o.codigo] })), formato: (v) => NG.fmt.num(v) + " filas" }),
        { columnas: [{ clave: "codigo", titulo: "Código" }, { clave: "nombre", titulo: "Origen" }, { clave: "n", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) }], filas: d.mediciones_por_origen },
        d.sql.mediciones_por_origen, "mediciones_origen");
      const pE = NG.panel({ titulo: "Eventos operativos por tipo", subtitulo: "Cambios de estado, fallas, mantenimientos y comunicación." });
      r.append(pE.raiz);
      NG.graf.tarjeta(pE, (g) => NG.graf.barras(g, { categorias: d.eventos_por_tipo.map((x) => x.nombre), valores: d.eventos_por_tipo.map((x) => x.n), formato: (v) => NG.fmt.num(v), nombreValor: "eventos" }),
        { columnas: [{ clave: "codigo", titulo: "Código" }, { clave: "nombre", titulo: "Tipo" }, { clave: "categoria", titulo: "Categoría" }, { clave: "n", titulo: "Eventos", num: true, formato: (v) => NG.fmt.num(v) }],
          filas: d.eventos_por_tipo }, d.sql.eventos_por_tipo, "eventos_tipo");

      const r2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r2);
      const pV = NG.panel({ titulo: "Luces encendidas en las viviendas", subtitulo: "Porcentaje de luces encendidas por hora (contador de casas de la maqueta y viviendas simuladas)." });
      r2.append(pV.raiz);
      const vp = d.viviendas_perfil;
      NG.graf.tarjeta(pV, (g) => NG.graf.linea(g, { x: vp.horas, alto: 230, formatoX: (v) => v + "h", formatoY: (v) => NG.fmt.num(v, 0) + " %", formatoTooltip: (v) => NG.fmt.num(v, 1) + " %",
        series: [{ nombre: "Viviendas simuladas", valores: vp.simuladas }, { nombre: "Casas de la maqueta", valores: vp.fisicas, color: "--s2" }] }),
        { columnas: [{ clave: "h", titulo: "Hora" }, { clave: "s", titulo: "Simuladas (%)", num: true }, { clave: "f", titulo: "Maqueta (%)", num: true }],
          filas: vp.horas.map((h, i) => ({ h, s: vp.simuladas[i], f: vp.fisicas[i] })) }, d.sql.viviendas, "viviendas");
      const pC = NG.panel({ titulo: "Consumo diario calculado", subtitulo: "Tabla consumo_energetico (dato CALCULADO por sp_calcular_consumo_diario)." });
      r2.append(pC.raiz);
      NG.graf.tarjeta(pC, (g) => NG.graf.linea(g, { x: d.consumo_calculado.map((x) => x.fecha), alto: 230, formatoX: (v) => NG.fmt.fechaCorta(v), formatoXTooltip: (v) => NG.fmt.fecha(v),
        formatoY: (v) => NG.fmt.num(v, 0), formatoTooltip: (v) => NG.fmt.num(v, 2) + " kWh", series: [{ nombre: "Energía calculada", valores: d.consumo_calculado.map((x) => x.energia_kwh), color: "--s3", area: true }] }),
        { columnas: [{ clave: "fecha", titulo: "Fecha" }, { clave: "energia_kwh", titulo: "kWh", num: true }, { clave: "referencia_kwh", titulo: "Referencia (kWh)", num: true },
          { clave: "imputados", titulo: "Intervalos imputados", num: true }], filas: d.consumo_calculado }, d.sql.consumo_calculado, "consumo_calculado");

      const cat = NG.estado.catalogos || { luminarias: [] };
      const pM = NG.panel({ titulo: "Mediciones (tabla principal)", subtitulo: "Paginación en el servidor: el navegador recibe solo 25 filas por página del millón de registros." });
      c.append(pM.raiz);
      navegadorPaginado(pM, "relacional/mediciones", [
        selector("Luminaria", "luminaria", [["", "Todas"]].concat(cat.luminarias.map((l) => [l.luminaria_id, l.codigo])), NG.estado.filtros.luminaria),
        fecha("Desde", "desde", ""), fecha("Hasta", "hasta", ""),
        selector("Origen", "origen", [["", "Todos"], ["1", "Simulado"], ["2", "Físico"], ["4", "Prueba"]]),
        selector("Estado", "estado", [["", "Todos"], ["1", "Apagada"], ["2", "Nivel base"], ["3", "Madrugada"], ["4", "Presencia"], ["5", "Ahorro"], ["6", "Encendida de día"], ["7", "Falla"], ["8", "Mantenimiento"]]),
      ], [
        { clave: "medicion_id", titulo: "medicion_id", num: true }, { clave: "fecha_hora", titulo: "Fecha y hora" }, { clave: "luminaria", titulo: "Luminaria" },
        { clave: "estado", titulo: "Estado" }, { clave: "origen", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v) }, { clave: "nivel_luz_lux", titulo: "Lux", num: true },
        { clave: "detecciones", titulo: "Detec.", num: true }, { clave: "brillo_pct", titulo: "Brillo (%)", num: true }, { clave: "tension_v", titulo: "Tensión (V)", num: true },
        { clave: "potencia_w", titulo: "Potencia (W)", num: true }, { clave: "energia_wh", titulo: "Energía (Wh)", num: true }, { clave: "es_anomala", titulo: "Anómala", formato: (v) => (v ? "Sí" : "No") },
      ]);
      const pEv = NG.panel({ titulo: "Eventos operativos", subtitulo: "Registro de cambios de estado, fallas, mantenimientos y conexión de los tableros." });
      c.append(pEv.raiz);
      navegadorPaginado(pEv, "relacional/eventos", [
        selector("Tipo", "tipo", [["", "Todos"]].concat(d.eventos_por_tipo.map((x) => [x.tipo_evento_id, x.nombre]))),
        selector("Origen", "origen", [["", "Todos"], ["1", "Simulado"], ["2", "Físico"]]),
      ], [
        { clave: "evento_id", titulo: "evento_id", num: true }, { clave: "fecha_hora", titulo: "Fecha y hora" }, { clave: "tipo", titulo: "Tipo" },
        { clave: "luminaria", titulo: "Luminaria", formato: (v) => v || "Tablero" }, { clave: "ubicacion", titulo: "Tramo" }, { clave: "origen", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v) },
        { clave: "estado_anterior", titulo: "Antes" }, { clave: "estado_nuevo", titulo: "Después" }, { clave: "detalle", titulo: "Detalle" },
      ]);
    },
  };

  // ================================================================== multidimensional
  NG.vistas.multidimensional = {
    titulo: "Modelo multidimensional",
    cubo: { hecho: "consumo", medida: "energia_kwh", filas: "zona", columnas: "anio_mes" },
    async render(c) {
      c.append(NG.encabezado("Modelo multidimensional · NeoGridDW", "Constelación de hechos: un esquema estrella por proceso (operación, consumo, fallas y mantenimiento) que comparte las mismas dimensiones conformadas. Claves sustitutas enteras y medidas listas para sumar."));
      const [d, diag] = await Promise.all([NG.api("dw/resumen"), NG.api("explorar/multidimensional/diagrama")]);
      const dims = d.tablas.filter((t) => t.categoria === "DIMENSION");
      const principal = d.tablas.find((t) => t.tabla === "fact_operacion_luminaria") || {};
      c.append(NG.cifras([
        { etiqueta: "Dimensiones", valor: NG.fmt.num(dims.length), nota: "Tiempo, hora, luminaria, ubicación, sensor, estado, origen, calidad…" },
        { etiqueta: "Tablas de hechos", valor: NG.fmt.num(d.hechos.length), nota: "1 transaccional, 2 agregados y 2 de eventos" },
        { etiqueta: "Hecho principal", valor: NG.fmt.num(principal.filas), nota: "fact_operacion_luminaria (luminaria × 15 min)" },
        { etiqueta: "Filas en el DW", valor: NG.fmt.compacto(d.tablas.reduce((a, t) => a + (t.filas || 0), 0)) },
      ]));
      const pD = NG.panel({ titulo: "Esquema en estrella (constelación)", subtitulo: "Arrastre para moverse, use la rueda para acercar y haga clic en una tabla para resaltar sus relaciones." });
      c.append(pD.raiz);
      const contD = NG.el("div");
      pD.cuerpo.append(contD);
      NG.diagrama(contD, diag, { alto: 600, alSeleccionar: (id) => { info.textContent = ""; const t = d.tablas.find((x) => x.tabla === id); if (t) info.append(NG.el("strong", { texto: id + ": " }), t.descripcion || "", " ", NG.el("a", { href: "#/explorador?modelo=multidimensional&tabla=" + id, texto: "Abrir en el explorador" })); } });
      const info = NG.el("p", { clase: "nota", estilo: "margin-top:8px", texto: "Seleccione una tabla del diagrama para ver su descripción." });
      pD.cuerpo.append(info);

      const pH = NG.panel({ titulo: "Tablas de hechos y su granularidad", subtitulo: "El grano define qué representa una fila; las medidas solo se suman dentro de ese grano." });
      c.append(pH.raiz);
      pH.cuerpo.append(NG.tabla([{ clave: "tabla", titulo: "Hecho", nodo: (v) => NG.el("a", { href: "#/explorador?modelo=multidimensional&tabla=" + v, texto: v }) },
        { clave: "grano", titulo: "Grano" }, { clave: "filas", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "dimensiones", titulo: "Dimensiones", formato: (v) => v.join(", ") }, { clave: "medidas", titulo: "Medidas", formato: (v) => v.join(", ") }], d.hechos));
      pH.cuerpo.querySelectorAll("td").forEach((td) => (td.style.whiteSpace = "normal"));

      const r = NG.el("div", { clase: "rejilla rejilla-1-2" });
      c.append(r);
      const pCal = NG.panel({ titulo: "Calidad del dato tras el ETL", subtitulo: "Dimensión dim_calidad_dato en el hecho principal." });
      r.append(pCal.raiz);
      const COLC = { ORIGINAL: "--s1", IMPUTADO: "--s4", ANOMALO: "--s2", IMPUTADO_Y_ANOMALO: "--s5" };
      NG.graf.tarjeta(pCal, (g) => NG.graf.segmentada(g, { partes: d.calidad.map((x) => ({ nombre: x.codigo.replace(/_/g, " ").toLowerCase().replace(/^./, (m) => m.toUpperCase()), valor: x.n, color: COLC[x.codigo], tintaOscura: x.codigo === "IMPUTADO" })),
        formato: (v) => NG.fmt.num(v) + " filas" }), { columnas: [{ clave: "codigo", titulo: "Calidad" }, { clave: "descripcion", titulo: "Descripción" }, { clave: "n", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) }], filas: d.calidad }, null, "calidad");
      pCal.cuerpo.append(NG.tabla([{ clave: "codigo", titulo: "Calidad" }, { clave: "n", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) }], d.calidad));

      // ----- cubo
      const pCubo = NG.panel({ titulo: "Análisis del cubo", subtitulo: "Elija un hecho, una medida y las dimensiones de filas y columnas. Los filtros de arriba hacen de corte (slice); cambiar de mes a semana o de zona a tramo es un drill-down." });
      r.append(pCubo.raiz);
      const cfg = this.cubo;
      const defs = d.cubos;
      const controles = NG.el("div", { clase: "filtro-fila" });
      const resultado = NG.el("div");
      pCubo.cuerpo.append(controles, resultado);
      const selHecho = NG.el("select", { "aria-label": "Hecho" }, Object.entries(defs).map(([k, v]) => NG.el("option", { value: k, selected: k === cfg.hecho }, v.nombre)));
      const selMedida = NG.el("select", { "aria-label": "Medida" });
      const selFilas = NG.el("select", { "aria-label": "Filas" });
      const selCols = NG.el("select", { "aria-label": "Columnas" });
      function opciones() {
        const def = defs[selHecho.value];
        [selMedida, selFilas, selCols].forEach(NG.vaciar);
        def.medidas.forEach((m) => selMedida.append(NG.el("option", { value: m.id, selected: m.id === cfg.medida }, m.nombre)));
        def.dimensiones.forEach((m) => selFilas.append(NG.el("option", { value: m.id, selected: m.id === cfg.filas }, m.nombre)));
        selCols.append(NG.el("option", { value: "" }, "Sin columnas"));
        def.dimensiones.forEach((m) => selCols.append(NG.el("option", { value: m.id, selected: m.id === cfg.columnas }, m.nombre)));
      }
      controles.append(NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: "Hecho" }), selHecho),
        NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: "Medida" }), selMedida),
        NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: "Filas" }), selFilas),
        NG.el("label", { clase: "campo" }, NG.el("span", { clase: "nota", texto: "Columnas" }), selCols));
      opciones();
      const bsql = NG.el("button", { type: "button", "aria-pressed": "false" }, "SQL");
      pCubo.acciones.append(bsql);
      const pre = NG.el("pre", { clase: "sql codigo", hidden: true });
      bsql.addEventListener("click", () => { pre.hidden = !pre.hidden; bsql.setAttribute("aria-pressed", String(!pre.hidden)); });
      pCubo.cuerpo.append(pre);
      async function consultar() {
        Object.assign(cfg, { hecho: selHecho.value, medida: selMedida.value, filas: selFilas.value, columnas: selCols.value });
        resultado.classList.add("recargando");
        let q;
        try { q = await NG.api("dw/cubo", NG.paramsFiltro({ hecho: cfg.hecho, medida: cfg.medida, filas: cfg.filas, columnas: cfg.columnas }), { signal: undefined }); }
        catch (e) { NG.vaciar(resultado); resultado.append(NG.aviso(e.message, true)); resultado.classList.remove("recargando"); return; }
        NG.vaciar(resultado);
        resultado.classList.remove("recargando");
        pre.textContent = q.sql;
        const dec = /pct|prom/.test(q.medida) ? 1 : 2;
        resultado.append(NG.el("p", { clase: "nota", texto: `${q.medida_nombre} por ${q.filas_nombre.toLowerCase()}${q.columnas ? " y " + q.columnas_nombre.toLowerCase() : ""} · total ${NG.fmt.num(q.total, dec)} · consulta en ${NG.fmt.num(q.ms, 0)} ms` }));
        const graf = NG.el("div", { estilo: "margin:8px 0 14px" });
        resultado.append(graf);
        if (!q.columnas) {
          NG.graf.barras(graf, { categorias: q.filas, valores: q.valores, formato: (v) => NG.fmt.num(v, dec), nombreValor: q.medida_nombre });
          resultado.append(NG.tabla([{ clave: "f", titulo: q.filas_nombre }, { clave: "v", titulo: q.medida_nombre, num: true, formato: (v) => NG.fmt.num(v, dec) }],
            q.filas.map((f, i) => ({ f, v: q.valores[i] })).concat([{ f: "Total", v: q.total }])));
        } else {
          NG.graf.mapaCalor(graf, { filas: q.filas, columnas: q.columnas, valores: q.matriz, formato: (v) => NG.fmt.num(v, dec), nombreValor: q.medida_nombre });
          const cols = [{ clave: "f", titulo: q.filas_nombre }].concat(q.columnas.map((cn, j) => ({ clave: "c" + j, titulo: cn, num: true, formato: (v) => NG.fmt.num(v, dec) })))
            .concat([{ clave: "t", titulo: "Total", num: true, formato: (v) => NG.fmt.num(v, dec) }]);
          const filas = q.filas.map((f, i) => Object.assign({ f, t: q.total_filas[i] }, ...q.columnas.map((_, j) => ({ ["c" + j]: q.matriz[i][j] }))));
          filas.push(Object.assign({ f: "Total", t: q.total }, ...q.columnas.map((_, j) => ({ ["c" + j]: q.total_columnas[j] }))));
          resultado.append(NG.tabla(cols, filas, { alta: true }));
        }
      }
      selHecho.addEventListener("change", () => { cfg.medida = null; cfg.filas = "zona"; cfg.columnas = ""; opciones(); consultar(); });
      [selMedida, selFilas, selCols].forEach((s) => s.addEventListener("change", consultar));
      consultar();
    },
  };

  // ================================================================== monitor ETL
  NG.vistas.etl = {
    titulo: "Monitor ETL",
    sinFiltros: true,
    seleccion: null,
    async render(c) {
      c.append(NG.encabezado("Monitor ETL", "Cada carga de NeoGridRelacional a NeoGridDW, sea con el paquete SSIS o con el ETL en T-SQL, queda registrada con sus pasos, sus filas y los rechazos de calidad."));
      const d = await NG.api("etl", { ejecucion: this.seleccion });
      const ult = d.ejecuciones[0] || {};
      const ctrl = d.control[0] || {};
      c.append(NG.cifras([
        { etiqueta: "Última ejecución", valor: ult.ejecucion_id ? "#" + ult.ejecucion_id : "—", nota: ult.estado ? (ult.herramienta === "SSIS" ? "SSIS" : "T-SQL") + " · " + ult.estado.replace("_", " ").toLowerCase() : "" },
        { etiqueta: "Filas insertadas (última)", valor: NG.fmt.num(ult.filas_insertadas), nota: "de " + NG.fmt.num(ult.filas_leidas) + " leídas" },
        { etiqueta: "Rechazadas (última)", valor: NG.fmt.num(ult.filas_rechazadas), nota: NG.fmt.num(ult.filas_imputadas) + " imputadas" },
        { etiqueta: "Marca de agua", valor: NG.fmt.num(ctrl.ultimo_medicion_id), nota: "Último medicion_id cargado" },
        { etiqueta: "Pendientes por cargar", valor: NG.fmt.num(d.pendientes_por_cargar), nota: d.pendientes_por_cargar ? "Nuevas mediciones aún no cargadas al DW" : "El DW está al día" },
      ]));
      const pE = NG.panel({ titulo: "Ejecuciones", subtitulo: "Haga clic en una ejecución para ver sus pasos y sus rechazos." });
      c.append(pE.raiz);
      pE.cuerpo.append(NG.tabla([
        { clave: "ejecucion_id", titulo: "#", num: true }, { clave: "herramienta", titulo: "Herramienta", formato: (v) => (v === "TSQL" ? "T-SQL" : v) },
        { clave: "estado", titulo: "Estado", nodo: (v) => NG.etiqueta(v === "EXITOSA" ? "Exitosa" : v === "CON_RECHAZOS" ? "Con rechazos" : v === "FALLIDA" ? "Fallida" : "En curso", v === "EXITOSA" ? "bueno" : v === "CON_RECHAZOS" ? "aviso" : v === "FALLIDA" ? "critico" : "neutra") },
        { clave: "inicio", titulo: "Inicio", formato: NG.fmt.fechaHora }, { clave: "fin", titulo: "Fin", formato: NG.fmt.fechaHora },
        { clave: "filas_leidas", titulo: "Leídas", num: true, formato: (v) => NG.fmt.num(v) }, { clave: "filas_insertadas", titulo: "Insertadas", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "filas_rechazadas", titulo: "Rechazadas", num: true, formato: (v) => NG.fmt.num(v) }, { clave: "filas_omitidas", titulo: "Omitidas", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "filas_imputadas", titulo: "Imputadas", num: true, formato: (v) => NG.fmt.num(v) }, { clave: "mensaje", titulo: "Mensaje", formato: (v) => v || "" },
      ], d.ejecuciones, { alta: true, alClic: (f) => { this.seleccion = f.ejecucion_id; NG.recargar(); }, clave: (f) => f.ejecucion_id, seleccion: d.seleccionada, vacio: "Todavía no se ha ejecutado el ETL." }));

      const r = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r);
      const pP = NG.panel({ titulo: "Pasos de la ejecución #" + (d.seleccionada || "—"), subtitulo: "Duración de cada paso en segundos." });
      r.append(pP.raiz);
      const pasos = d.pasos.map((p) => Object.assign({}, p, { segundos: Math.max(0, (new Date(String(p.fin).replace(" ", "T")) - new Date(String(p.inicio).replace(" ", "T"))) / 1000) }));
      NG.graf.tarjeta(pP, (g) => pasos.length ? NG.graf.barras(g, { categorias: pasos.map((p) => p.paso), valores: pasos.map((p) => p.segundos), formato: (v) => NG.fmt.num(v, 0) + " s",
        extra: pasos.map((p) => ({ color: p.estado === "ERROR" ? "--critico" : "--s1", tooltip: [{ valor: NG.fmt.num(p.filas), etiqueta: "filas" }] })) }) : g.append(NG.el("p", { clase: "nota", texto: "Sin pasos registrados." })),
        { columnas: [{ clave: "paso", titulo: "Paso" }, { clave: "inicio", titulo: "Inicio" }, { clave: "fin", titulo: "Fin" }, { clave: "filas", titulo: "Filas", num: true, formato: (v) => NG.fmt.num(v) },
          { clave: "estado", titulo: "Estado" }, { clave: "mensaje", titulo: "Mensaje" }], filas: pasos }, null, "pasos_etl");
      const pR = NG.panel({ titulo: "Rechazos por motivo", subtitulo: d.rechazos_seleccionada.length ? "En la ejecución seleccionada." : "Historial completo del ETL." });
      r.append(pR.raiz);
      const mot = d.rechazos_seleccionada.length ? d.rechazos_seleccionada : d.rechazos_por_motivo;
      const MOT = { DUPLICADO: "Duplicado (mismo intervalo)", FECHA_INVALIDA: "Fecha fuera de rango", BRILLO_FUERA_DE_RANGO: "Brillo fuera de 0–100 % o nulo", VALOR_IMPOSIBLE: "Valor físicamente imposible", CLAVE_SIN_DIMENSION: "Clave sin dimensión" };
      NG.graf.tarjeta(pR, (g) => mot.length ? NG.graf.barras(g, { categorias: mot.map((m) => MOT[m.motivo] || m.motivo), valores: mot.map((m) => m.n), formato: (v) => NG.fmt.num(v), nombreValor: "filas rechazadas" })
        : g.append(NG.el("p", { clase: "nota", texto: "Sin rechazos. La prueba 09_prueba_rechazos_etl.sql genera 9 rechazos controlados." })),
        { columnas: [{ clave: "motivo", titulo: "Motivo" }, { clave: "n", titulo: "Filas", num: true }], filas: mot }, null, "rechazos_motivo");

      const pU = NG.panel({ titulo: "Últimos rechazos", subtitulo: "Tabla etl_rechazo: la fila de origen, el motivo y el detalle." });
      c.append(pU.raiz);
      pU.cuerpo.append(NG.tabla([{ clave: "rechazo_id", titulo: "#", num: true }, { clave: "ejecucion_id", titulo: "Ejecución", num: true }, { clave: "medicion_id", titulo: "medicion_id", num: true },
        { clave: "motivo", titulo: "Motivo" }, { clave: "detalle", titulo: "Detalle" }, { clave: "fecha_rechazo", titulo: "Fecha", formato: NG.fmt.fechaHora }], d.ultimos_rechazos, { alta: true, vacio: "No hay rechazos registrados." }));

      const r2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r2);
      const pH = NG.panel({ titulo: "Por herramienta", subtitulo: "SSIS y T-SQL escriben en las mismas tablas de control." });
      r2.append(pH.raiz);
      pH.cuerpo.append(NG.tabla([{ clave: "herramienta", titulo: "Herramienta", formato: (v) => (v === "TSQL" ? "T-SQL" : v) }, { clave: "ejecuciones", titulo: "Ejecuciones", num: true },
        { clave: "leidas", titulo: "Leídas", num: true, formato: (v) => NG.fmt.num(v) }, { clave: "insertadas", titulo: "Insertadas", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "rechazadas", titulo: "Rechazadas", num: true, formato: (v) => NG.fmt.num(v) }], d.por_herramienta));
      const pI = NG.panel({ titulo: "Integración con la maqueta", subtitulo: "Marcas de agua de sp_importar_maqueta (NeoGridAlumbrado → NeoGridRelacional)." });
      r2.append(pI.raiz);
      pI.cuerpo.append(NG.tabla([{ clave: "proceso", titulo: "Proceso" }, { clave: "ultimo_id_origen", titulo: "Último id", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "ultima_marca", titulo: "Hasta", formato: NG.fmt.fechaHora }, { clave: "ultima_ejecucion", titulo: "Ejecutado", formato: NG.fmt.fechaHora },
        { clave: "filas_ultima_ejecucion", titulo: "Filas", num: true }], d.integracion_maqueta));
    },
  };

  // ================================================================== comparación
  const DIFERENCIAS = [
    ["Propósito", "Registrar la operación diaria sin redundancia y con integridad (OLTP).", "Analizar grandes volúmenes por varias perspectivas a la vez (OLAP)."],
    ["Estructura", "21 tablas en tercera forma normal: catálogos, maestras, transaccionales, calculadas y de control.", "Constelación: 5 hechos que comparten 11 dimensiones conformadas, más 4 tablas de control del ETL."],
    ["Claves", "Claves naturales o de identidad del negocio (luminaria_id, sensor_id) y FK entre tablas.", "Claves sustitutas enteras (luminaria_key…) y la clave natural se guarda como atributo; miembros «desconocido» con clave 0."],
    ["Granularidad", "Cada tabla guarda su entidad; la medición es una luminaria cada 15 minutos.", "El grano se declara por hecho: 15 minutos, día, hora × tramo × estado, falla y orden de mantenimiento."],
    ["Redundancia", "Mínima: la zona está solo en zona; se llega a ella con tres JOIN.", "Controlada: dim_ubicacion repite el nombre y tipo de zona para evitar JOIN en las consultas."],
    ["Calidad", "Guarda la lectura cruda, con sus nulos y errores, para no perder trazabilidad.", "Guarda valores limpios: imputados y marcados con dim_calidad_dato; los inválidos van a etl_rechazo."],
    ["Escritura", "Inserciones continuas desde la simulación y la maqueta (MQTT → Python → SQL Server).", "Cargas por lotes con el ETL (SSIS o T-SQL) y marca de agua para no duplicar."],
    ["Consultas típicas", "«¿Cuál fue la última lectura del poste O-P3?», «¿qué fallas siguen abiertas?»", "«¿Cuánta energía ahorró cada zona por mes?», «¿cómo varía el brillo por franja y tipo de zona?»"],
    ["Índices", "B-tree por luminaria y fecha para lecturas puntuales.", "Columnstore no agrupado en el hecho principal y hechos agregados para lecturas masivas."],
  ];

  NG.vistas.comparacion = {
    titulo: "Comparación de modelos",
    sinFiltros: true,
    caso: "consumo_zona", completo: false,
    async render(c) {
      c.append(NG.encabezado("Comparación de los dos modelos", "Los mismos datos de alumbrado guardados para dos trabajos distintos: operar la red y analizarla."));
      const d = await NG.api("comparacion");
      const m = d.modelos;
      const lado = (titulo, x, nombre) => NG.el("div", null, NG.el("h2", { texto: titulo }), NG.el("p", { clase: "nota", texto: nombre }),
        NG.el("dl", { estilo: "display:grid;grid-template-columns:auto 1fr;gap:4px 14px;margin:10px 0 0" },
          NG.el("dt", { texto: "Tablas" }), NG.el("dd", { estilo: "margin:0", texto: NG.fmt.num(x.tablas) }),
          NG.el("dt", { texto: "Columnas" }), NG.el("dd", { estilo: "margin:0", texto: NG.fmt.num(x.columnas) }),
          NG.el("dt", { texto: "Filas" }), NG.el("dd", { estilo: "margin:0", texto: NG.fmt.num(x.filas) }),
          NG.el("dt", { texto: "Relaciones (FK)" }), NG.el("dd", { estilo: "margin:0", texto: NG.fmt.num(x.relaciones) }),
          NG.el("dt", { texto: "Índices" }), NG.el("dd", { estilo: "margin:0", texto: NG.fmt.num(x.indices) }),
          NG.el("dt", { texto: "Tabla principal" }), NG.el("dd", { estilo: "margin:0", texto: x.principal + " · " + NG.fmt.num(x.filas_principal) + " filas" }),
          NG.el("dt", { texto: "Por categoría" }), NG.el("dd", { estilo: "margin:0", texto: Object.entries(x.por_categoria).map(([k, v]) => (CAT[k] || k) + " " + v.tablas).join(" · ") })));
      c.append(NG.el("div", { clase: "comparacion" }, lado("Relacional", m.rel, "NeoGridRelacional · normalizado"), lado("Multidimensional", m.dw, "NeoGridDW · constelación de estrellas")));

      const pD = NG.panel({ titulo: "Diferencias de diseño" });
      c.append(pD.raiz);
      pD.cuerpo.append(NG.el("div", { clase: "tabla-envoltura" }, NG.el("table", { clase: "datos tabla-diferencias" },
        NG.el("thead", null, NG.el("tr", null, NG.el("th", { texto: "Aspecto" }), NG.el("th", { texto: "Relacional" }), NG.el("th", { texto: "Multidimensional" }))),
        NG.el("tbody", null, DIFERENCIAS.map((f) => NG.el("tr", null, f.map((t) => NG.el("td", { texto: t }))))))));

      const pB = NG.panel({ titulo: "La misma pregunta en los dos modelos", subtitulo: "Se ejecutan tres consultas equivalentes en este servidor y se mide su tiempo." });
      c.append(pB.raiz);
      const selCaso = NG.el("select", { "aria-label": "Pregunta" }, d.casos.map((x) => NG.el("option", { value: x.id, selected: x.id === this.caso }, x.titulo)));
      const selRango = NG.el("select", { "aria-label": "Periodo" }, NG.el("option", { value: "30", selected: !this.completo }, "Últimos 30 días de la simulación"), NG.el("option", { value: "todo", selected: this.completo }, "Todo el periodo (1 millón de filas)"));
      const boton = NG.el("button", { type: "button", clase: "boton boton-principal" }, "Ejecutar las consultas");
      const salida = NG.el("div", { estilo: "margin-top:12px" });
      pB.cuerpo.append(NG.el("div", { clase: "filtro-fila" }, selCaso, selRango, boton), salida);
      const ext = d.extension;
      const ejecutar = async () => {
        this.caso = selCaso.value; this.completo = selRango.value === "todo";
        boton.disabled = true; boton.textContent = "Consultando…";
        salida.classList.add("recargando");
        try {
          const prm = { caso: this.caso };
          if (this.completo) { prm.desde = ext.desde; prm.hasta = ext.hasta; }
          const q = await NG.api("comparacion/consulta", prm, { signal: undefined });
          NG.vaciar(salida);
          salida.append(NG.el("p", { clase: "nota", texto: `${q.titulo} · ${NG.fmt.fecha(q.desde)} a ${NG.fmt.fecha(q.hasta)} · motor: ${q.motor === "sqlite" ? "copia SQLite en la nube" : "SQL Server"}` }));
          const max = Math.max(1, ...q.resultados.map((x) => x.ms || 0));
          q.resultados.forEach((x, i) => salida.append(NG.el("div", { clase: "tiempo-barra" }, NG.el("span", { clase: "nombre", texto: x.nombre }),
            NG.el("span", { clase: "pista" }, NG.el("span", { clase: "relleno" + (i === 0 ? " contexto" : ""), estilo: "width:" + (100 * (x.ms || max)) / max + "%" })),
            NG.el("span", { clase: "ms", texto: x.ms === null ? "> 30 s" : NG.fmt.num(x.ms, 0) + " ms" }))));
          const grupos = q.resultados[0].filas.map((f) => f.grupo);
          const tabla = grupos.map((g) => Object.assign({ grupo: g }, ...q.resultados.map((x, i) => ({ ["r" + i]: (x.filas.find((f) => f.grupo === g) || {}).valor }))));
          salida.append(NG.el("h3", { estilo: "margin:14px 0 6px", texto: "Resultados (" + q.unidad + ")" }),
            NG.tabla([{ clave: "grupo", titulo: "Grupo" }].concat(q.resultados.map((x, i) => ({ clave: "r" + i, titulo: x.nombre, num: true, formato: (v) => NG.fmt.num(v, 2) }))), tabla));
          q.resultados.forEach((x) => salida.append(NG.el("details", { estilo: "margin-top:8px" }, NG.el("summary", { texto: "SQL · " + x.nombre }), NG.el("pre", { clase: "sql codigo", texto: x.sql }))));
          salida.append(NG.el("p", { clase: "nota", estilo: "margin-top:10px", texto: "El modelo relacional recorre la tabla de mediciones y une cuatro tablas para llegar a la zona; el hecho detallado ya trae la clave de ubicación; el hecho agregado responde con unas pocas miles de filas. Pequeñas diferencias en kWh vienen de la regla de imputación del ETL para energías negativas o nulas." }));
        } catch (e) { NG.vaciar(salida); salida.append(NG.aviso(e.message, true)); }
        salida.classList.remove("recargando");
        boton.disabled = false; boton.textContent = "Ejecutar las consultas";
      };
      boton.addEventListener("click", ejecutar);
      ejecutar();
    },
  };
})();
