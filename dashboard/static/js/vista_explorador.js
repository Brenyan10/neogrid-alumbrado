/* NeoGrid · Explorador de datos de los dos modelos: tablas, columnas, tipos, claves, relaciones,
   índices, número de filas, datos paginados en el servidor con filtros y orden, y diagrama interactivo. */
(function () {
  "use strict";
  const NG = window.NG;
  NG.vistas = NG.vistas || {};
  const CAT = { CATALOGO: "Catálogos", MAESTRA: "Maestras", TRANSACCIONAL: "Transaccionales", CALCULADA: "Calculadas", CONTROL: "Control",
    DIMENSION: "Dimensiones", HECHO: "Hechos", HECHO_AGREGADO: "Hechos agregados", ETL: "Control del ETL" };
  const ORDEN_CAT = ["TRANSACCIONAL", "MAESTRA", "CATALOGO", "CALCULADA", "CONTROL", "HECHO", "HECHO_AGREGADO", "DIMENSION", "ETL"];
  const OPS = [["eq", "="], ["ne", "≠"], ["gt", ">"], ["ge", "≥"], ["lt", "<"], ["le", "≤"], ["contiene", "contiene"], ["empieza", "empieza por"], ["nulo", "es nulo"], ["no_nulo", "no es nulo"]];

  NG.vistas.explorador = {
    titulo: "Explorador de datos",
    sinFiltros: true,
    estado: { modelo: "relacional", tabla: null, pestana: "datos", pagina: 1, tam: 25, orden: null, dir: "asc", filtros: [] },
    async render(c, params) {
      const st = this.estado;
      if (params.get("modelo")) {
        const nuevo = params.get("modelo") === "multidimensional" ? "multidimensional" : "relacional";
        if (nuevo !== st.modelo) Object.assign(st, { modelo: nuevo, tabla: null });
      }
      if (params.get("tabla") && params.get("tabla") !== st.tabla) Object.assign(st, { tabla: params.get("tabla"), pagina: 1, orden: null, filtros: [] });
      if (params.get("pestana")) st.pestana = params.get("pestana");

      const selModelo = NG.el("div", { clase: "selector-modelo", role: "group", "aria-label": "Modelo" },
        ["relacional", "multidimensional"].map((m) => NG.el("button", { type: "button", "aria-pressed": String(st.modelo === m),
          onclick: () => { location.hash = "#/explorador?modelo=" + m; } }, m === "relacional" ? "Relacional · NeoGridRelacional" : "Multidimensional · NeoGridDW")));
      c.append(NG.el("div", { clase: "titulo-vista" }, NG.el("h1", { texto: "Explorador de datos" }), selModelo),
        NG.el("p", { clase: "nota", texto: "Estructura y datos reales de cada tabla. Los datos se paginan, filtran y ordenan en el servidor: el navegador nunca descarga el millón de filas." }));

      const lista = await NG.api("explorar/" + st.modelo + "/tablas");
      if (!st.tabla || !lista.tablas.some((t) => t.tabla === st.tabla)) {
        st.tabla = st.modelo === "relacional" ? "medicion" : "fact_operacion_luminaria";
        st.pagina = 1; st.orden = null; st.filtros = [];
      }
      const cuerpo = NG.el("div", { clase: "explorador" + (st.pestana === "diagrama" ? " solo-diagrama" : "") });
      c.append(cuerpo);

      // ---------------- lista de tablas
      const izq = NG.el("aside", { clase: "lista-tablas panel", "aria-label": "Tablas" });
      const buscar = NG.el("input", { type: "search", placeholder: "Buscar tabla", "aria-label": "Buscar tabla" });
      const contLista = NG.el("div");
      izq.append(NG.el("p", { clase: "nota", texto: `${NG.fmt.num(lista.totales.tablas)} tablas · ${NG.fmt.num(lista.totales.filas)} filas · ${NG.fmt.num(lista.totales.relaciones)} relaciones · ${NG.fmt.num(lista.totales.indices)} índices` }), buscar, contLista);
      const pintarLista = () => {
        NG.vaciar(contLista);
        const q = buscar.value.trim().toLowerCase();
        const grupos = {};
        lista.tablas.filter((t) => !q || t.tabla.includes(q)).forEach((t) => (grupos[t.categoria] = grupos[t.categoria] || []).push(t));
        Object.keys(grupos).sort((a, b) => ORDEN_CAT.indexOf(a) - ORDEN_CAT.indexOf(b)).forEach((g) => {
          contLista.append(NG.el("h3", { texto: CAT[g] || g }));
          grupos[g].forEach((t) => contLista.append(NG.el("button", { type: "button", "aria-current": String(t.tabla === st.tabla), title: t.descripcion || "",
            onclick: () => { location.hash = "#/explorador?modelo=" + st.modelo + "&tabla=" + encodeURIComponent(t.tabla) + "&pestana=" + (st.pestana === "diagrama" ? "datos" : st.pestana); } },
            NG.el("span", { texto: t.tabla }), NG.el("span", { texto: NG.fmt.compacto(t.filas) }))));
        });
      };
      buscar.addEventListener("input", pintarLista);
      pintarLista();
      cuerpo.append(izq);

      // ---------------- detalle
      const der = NG.el("section", { clase: "panel", "aria-label": "Tabla " + st.tabla });
      cuerpo.append(der);
      const info = await NG.api("explorar/" + st.modelo + "/tabla/" + encodeURIComponent(st.tabla));
      const t = info.tabla;
      der.append(NG.el("header", { estilo: "margin-bottom:10px" }, NG.el("h2", { texto: t.tabla }),
        NG.el("p", { clase: "nota", texto: `${CAT[t.categoria] || t.categoria} · ${NG.fmt.num(t.filas)} filas · ${NG.fmt.num(t.columnas)} columnas` + (t.descripcion ? " · " + t.descripcion : "") })));
      const pest = NG.el("div", { clase: "pestanas", role: "tablist" });
      const zona = NG.el("div");
      der.append(pest, zona);
      const PESTANAS = [["datos", "Datos"], ["estructura", "Columnas y claves"], ["relaciones", "Relaciones e índices"], ["diagrama", "Diagrama del modelo"]];
      PESTANAS.forEach(([id, nombre]) => pest.append(NG.el("button", { type: "button", role: "tab", "aria-selected": String(st.pestana === id),
        onclick: () => { st.pestana = id; location.hash = "#/explorador?modelo=" + st.modelo + "&tabla=" + encodeURIComponent(st.tabla) + "&pestana=" + id; } }, nombre)));

      if (st.pestana === "estructura") {
        zona.append(NG.tabla([
          { clave: "orden", titulo: "#", num: true }, { clave: "columna", titulo: "Columna", nodo: (v, f) => NG.el("span", null, f.es_pk ? NG.el("span", { clase: "marca-pk", texto: "PK" }) : null, f.es_fk ? NG.el("span", { clase: "marca-fk", texto: "FK" }) : null, v) },
          { clave: "tipo_completo", titulo: "Tipo SQL Server" }, { clave: "admite_nulos", titulo: "Nulos", formato: (v) => (v ? "Sí" : "No") },
          { clave: "es_identidad", titulo: "Identidad", formato: (v) => (v ? "Sí" : "") },
          { clave: "tabla_referenciada", titulo: "Referencia", nodo: (v, f) => v ? NG.el("a", { href: "#/explorador?modelo=" + st.modelo + "&tabla=" + v + "&pestana=estructura", texto: v + "." + f.columna_referenciada }) : NG.el("span", { texto: "" }) },
          { clave: "columna", titulo: "Indexada", formato: (v) => (info.columnas_indexadas.includes(v) ? "Sí" : "") },
        ], info.columnas));
      } else if (st.pestana === "relaciones") {
        const enlace = (tb) => NG.el("a", { href: "#/explorador?modelo=" + st.modelo + "&tabla=" + tb + "&pestana=relaciones", texto: tb });
        zona.append(NG.el("h3", { texto: "Esta tabla referencia a (claves foráneas)" }),
          NG.tabla([{ clave: "restriccion", titulo: "Restricción" }, { clave: "columna_origen", titulo: "Columna" }, { clave: "tabla_destino", titulo: "Tabla referenciada", nodo: enlace }, { clave: "columna_destino", titulo: "Columna referenciada" }],
            info.relaciones_salientes, { vacio: "No tiene claves foráneas." }),
          NG.el("h3", { estilo: "margin-top:16px", texto: "Tablas que la referencian" }),
          NG.tabla([{ clave: "tabla_origen", titulo: "Tabla", nodo: enlace }, { clave: "columna_origen", titulo: "Columna" }, { clave: "restriccion", titulo: "Restricción" }],
            info.relaciones_entrantes, { vacio: "Ninguna tabla la referencia." }),
          NG.el("h3", { estilo: "margin-top:16px", texto: "Índices" }),
          NG.tabla([{ clave: "indice", titulo: "Índice" }, { clave: "tipo", titulo: "Tipo" }, { clave: "es_pk", titulo: "PK", formato: (v) => (v ? "Sí" : "") },
            { clave: "es_unico", titulo: "Único", formato: (v) => (v ? "Sí" : "") }, { clave: "columnas", titulo: "Columnas clave" }, { clave: "columnas_incluidas", titulo: "Incluidas", formato: (v) => v || "" }], info.indices));
      } else if (st.pestana === "diagrama") {
        const diag = await NG.api("explorar/" + st.modelo + "/diagrama");
        const cont = NG.el("div");
        zona.append(NG.el("p", { clase: "nota", texto: st.modelo === "relacional" ? "Diagrama entidad-relación de NeoGridRelacional. Haga clic en una tabla para abrirla." : "Esquema en estrella de NeoGridDW (constelación de hechos). Haga clic en una tabla para abrirla." }), cont);
        const d = NG.diagrama(cont, diag, { alto: 640, alSeleccionar: (id) => { setTimeout(() => { location.hash = "#/explorador?modelo=" + st.modelo + "&tabla=" + id + "&pestana=estructura"; }, 450); } });
        d.seleccionar(st.tabla);
      } else {
        this.datos(zona, info);
      }
    },

    // ---------------- pestaña de datos
    datos(zona, info) {
      const st = this.estado;
      const cols = info.columnas.map((c) => c.columna);
      const filtrosUI = NG.el("div");
      const resultado = NG.el("div");
      const sqlPre = NG.el("pre", { clase: "sql codigo", hidden: true });
      const filas = st.filtros.length ? st.filtros.slice() : [];
      function filaFiltro(f) {
        const sc = NG.el("select", { "aria-label": "Columna" }, cols.map((c) => NG.el("option", { value: c, selected: f && f.columna === c }, c + (info.columnas_indexadas.includes(c) ? " (indexada)" : ""))));
        const so = NG.el("select", { "aria-label": "Operador" }, OPS.map(([v, t]) => NG.el("option", { value: v, selected: f && f.operador === v }, t)));
        const iv = NG.el("input", { type: "text", value: (f && f.valor) || "", "aria-label": "Valor", placeholder: "valor" });
        const quitar = NG.el("button", { type: "button", clase: "boton-texto", "aria-label": "Quitar filtro" }, "Quitar");
        const nodo = NG.el("div", { clase: "filtro-fila" }, sc, so, iv, quitar);
        const obj = { nodo, leer: () => ({ columna: sc.value, operador: so.value, valor: iv.value }) };
        quitar.addEventListener("click", () => { const i = ui.indexOf(obj); if (i >= 0) ui.splice(i, 1); nodo.remove(); });
        iv.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); aplicar(); } });
        return obj;
      }
      const ui = filas.map(filaFiltro);
      ui.forEach((u) => filtrosUI.append(u.nodo));
      const bAgregar = NG.el("button", { type: "button", clase: "boton" }, "Agregar filtro");
      bAgregar.addEventListener("click", () => { if (ui.length >= 3) return; const u = filaFiltro(null); ui.push(u); filtrosUI.append(u.nodo); });
      const bAplicar = NG.el("button", { type: "button", clase: "boton boton-principal" }, "Aplicar");
      const selTam = NG.el("select", { "aria-label": "Filas por página" }, [25, 50, 100].map((n) => NG.el("option", { value: n, selected: st.tam === n }, n + " filas por página")));
      const bSql = NG.el("button", { type: "button", clase: "boton", "aria-pressed": "false" }, "Ver SQL");
      bSql.addEventListener("click", () => { sqlPre.hidden = !sqlPre.hidden; bSql.setAttribute("aria-pressed", String(!sqlPre.hidden)); });
      const bCsv = NG.el("button", { type: "button", clase: "boton" }, "Descargar página (CSV)");
      let ultimo = null;
      bCsv.addEventListener("click", () => { if (ultimo) NG.descargarCSV(st.tabla + "_p" + ultimo.pagina + ".csv", ultimo.columnas, ultimo.filas); });
      const aplicar = () => { st.filtros = ui.map((u) => u.leer()).filter((f) => f.columna); st.pagina = 1; cargar(); };
      bAplicar.addEventListener("click", aplicar);
      selTam.addEventListener("change", () => { st.tam = parseInt(selTam.value, 10); st.pagina = 1; cargar(); });
      zona.append(filtrosUI, NG.el("div", { clase: "filtro-fila" }, bAgregar, bAplicar, selTam, bSql, bCsv),
        info.columnas_indexadas.length ? NG.el("p", { clase: "nota", texto: "Columnas indexadas (filtran y ordenan rápido): " + info.columnas_indexadas.join(", ") + "." }) : null,
        resultado, sqlPre);

      const tablaActual = st.tabla;
      const cargar = async () => {
        resultado.classList.add("recargando");
        const params = { pagina: st.pagina, tam: st.tam, orden: st.orden, dir: st.dir, f: st.filtros.map((f) => f.columna + "|" + f.operador + "|" + (f.valor || "")) };
        let d;
        try { d = await NG.api("explorar/" + st.modelo + "/tabla/" + encodeURIComponent(tablaActual) + "/datos", params); }
        catch (e) { if (e.name === "AbortError") return; NG.vaciar(resultado); resultado.append(NG.aviso(e.message, true)); resultado.classList.remove("recargando"); return; }
        ultimo = d;
        NG.vaciar(resultado);
        resultado.classList.remove("recargando");
        sqlPre.textContent = d.sql;
        resultado.append(NG.el("p", { clase: "nota", texto: `${d.total_exacto ? NG.fmt.num(d.total) : "Más filas de las que se pueden contar rápido"} filas${d.filtros.length ? " con el filtro" : ""} · página consultada en ${NG.fmt.num(d.ms, 0)} ms` }));
        const meta = Object.fromEntries(info.columnas.map((c) => [c.columna, c]));
        const columnas = d.columnas.map((c, i) => {
          const tipo = (meta[c] && meta[c].tipo) || "";
          return { clave: c, indice: i, titulo: c, num: /int|decimal|numeric|float|real|money/.test(tipo) && !/^(bit)$/.test(tipo),
            formato: (v) => (typeof v === "number" && !Number.isInteger(v) ? NG.fmt.num(v, 3) : String(v)) };
        });
        resultado.append(NG.tabla(columnas, d.filas, { alta: true, textoNulo: "NULL", orden: d.orden || (info.columnas.find((x) => x.es_pk) || {}).columna, dir: d.dir,
          ordenar: (k) => { if (st.orden === k) st.dir = st.dir === "asc" ? "desc" : "asc"; else { st.orden = k; st.dir = "asc"; } st.pagina = 1; cargar(); } }));
        resultado.append(NG.paginador(d.pagina, d.tam, d.total_exacto ? d.total : null, (p) => { st.pagina = p; cargar(); }));
      };
      cargar();
    },
  };
})();
