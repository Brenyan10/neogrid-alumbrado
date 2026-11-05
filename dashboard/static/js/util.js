/* NeoGrid · utilidades comunes: API, formatos, DOM seguro (textContent), tablas y tooltip. */
(function () {
  "use strict";
  const NG = (window.NG = window.NG || {});

  NG.estado = { filtros: {}, catalogos: null, meta: null, vista: null, controlador: null };

  // ------------------------------------------------------------------ API
  NG.qs = function (params) {
    const u = new URLSearchParams();
    Object.entries(params || {}).forEach(([k, v]) => {
      if (Array.isArray(v)) v.forEach((x) => u.append(k, x));
      else if (v !== undefined && v !== null && v !== "") u.append(k, v);
    });
    const s = u.toString();
    return s ? "?" + s : "";
  };

  NG.api = async function (ruta, params, opciones) {
    const señal = (opciones && opciones.signal) || (NG.estado.controlador && NG.estado.controlador.signal);
    const resp = await fetch("/api/" + ruta + NG.qs(params), { signal: señal, headers: { Accept: "application/json" } });
    let cuerpo = null;
    try { cuerpo = await resp.json(); } catch (e) { cuerpo = null; }
    if (!resp.ok) {
      const error = new Error((cuerpo && cuerpo.error) || "El servidor respondió con el código " + resp.status + ".");
      error.estado = resp.status;
      throw error;
    }
    return cuerpo;
  };

  NG.paramsFiltro = function (extra) {
    const f = NG.estado.filtros;
    const p = { desde: f.desde, hasta: f.hasta, luminaria: f.luminaria, origen: f.origen };
    if (f.ubicacion && f.ubicacion.startsWith("z:")) p.zona = f.ubicacion.slice(2);
    if (f.ubicacion && f.ubicacion.startsWith("u:")) p.ubicacion = f.ubicacion.slice(2);
    return Object.assign(p, extra || {});
  };

  // ------------------------------------------------------------------ formatos (es-CO)
  const nf = {};
  function numero(v, dec) {
    if (v === null || v === undefined || v === "" || Number.isNaN(Number(v))) return "—";
    const d = dec === undefined ? 0 : dec;
    const k = String(d);
    nf[k] = nf[k] || new Intl.NumberFormat("es-CO", { minimumFractionDigits: d, maximumFractionDigits: d });
    return nf[k].format(Number(v));
  }
  NG.fmt = {
    num: numero,
    pct: (v, dec) => (v === null || v === undefined ? "—" : numero(v, dec === undefined ? 1 : dec) + " %"),
    compacto: function (v) {
      if (v === null || v === undefined) return "—";
      const a = Math.abs(v);
      if (a >= 1e6) return numero(v / 1e6, a >= 1e7 ? 1 : 2) + " M";
      if (a >= 1e4) return numero(v / 1e3, a >= 1e5 ? 0 : 1) + " mil";
      return numero(v, a < 10 && a % 1 ? 1 : 0);
    },
    cop: (v) => (v === null || v === undefined ? "—" : "$ " + numero(v, 0)),
    fecha: function (s) {
      if (!s) return "—";
      const d = new Date(String(s).slice(0, 10) + "T12:00:00");
      return d.toLocaleDateString("es-CO", { day: "numeric", month: "short", year: "numeric" });
    },
    fechaCorta: function (s) {
      if (!s) return "";
      const d = new Date(String(s).slice(0, 10) + "T12:00:00");
      return d.toLocaleDateString("es-CO", { day: "numeric", month: "short" });
    },
    fechaHora: (s) => (s ? String(s).slice(0, 16).replace("T", " ") : "—"),
    horas: (v) => (v === null || v === undefined ? "—" : numero(v, v < 10 ? 1 : 0) + " h"),
  };

  // ------------------------------------------------------------------ DOM seguro
  NG.el = function (etiqueta, atributos) {
    const nodo = document.createElement(etiqueta);
    const attrs = atributos || {};
    Object.keys(attrs).forEach((k) => {
      const v = attrs[k];
      if (v === undefined || v === null || v === false) return;
      if (k === "texto") nodo.textContent = v;
      else if (k === "clase") nodo.className = v;
      else if (k.startsWith("on") && typeof v === "function") nodo.addEventListener(k.slice(2), v);
      else if (k === "estilo") nodo.setAttribute("style", v);
      else nodo.setAttribute(k, v === true ? "" : v);
    });
    for (let i = 2; i < arguments.length; i++) {
      const hijo = arguments[i];
      if (hijo === null || hijo === undefined || hijo === false) continue;
      if (Array.isArray(hijo)) hijo.forEach((h) => h && nodo.append(h));
      else nodo.append(hijo.nodeType ? hijo : document.createTextNode(String(hijo)));
    }
    return nodo;
  };
  NG.svg = function (etiqueta, atributos) {
    const nodo = document.createElementNS("http://www.w3.org/2000/svg", etiqueta);
    Object.entries(atributos || {}).forEach(([k, v]) => {
      if (v === undefined || v === null) return;
      if (k === "texto") nodo.textContent = v;
      else nodo.setAttribute(k, v);
    });
    return nodo;
  };
  NG.vaciar = function (nodo) {
    while (nodo.firstChild) nodo.removeChild(nodo.firstChild);
    return nodo;
  };

  // ------------------------------------------------------------------ piezas de interfaz
  NG.encabezado = function (titulo, descripcion) {
    return NG.el("div", { clase: "titulo-vista" }, NG.el("h1", { texto: titulo }), descripcion ? NG.el("p", { texto: descripcion }) : null);
  };

  NG.panel = function (opciones) {
    const acciones = NG.el("div", { clase: "panel-acciones" });
    const cuerpo = NG.el("div", { clase: "panel-cuerpo" });
    const raiz = NG.el("section", { clase: "panel" + (opciones.clase ? " " + opciones.clase : ""), "aria-label": opciones.titulo },
      NG.el("header", null,
        NG.el("div", { clase: "titulos" }, NG.el("h2", { texto: opciones.titulo }), opciones.subtitulo ? NG.el("p", { texto: opciones.subtitulo }) : null),
        acciones),
      cuerpo);
    return { raiz, cuerpo, acciones };
  };

  NG.cifras = function (lista) {
    return NG.el("div", { clase: "cifras" }, lista.map((c) =>
      NG.el("div", { clase: "cifra" },
        NG.el("p", { clase: "cifra-etiqueta", texto: c.etiqueta }),
        NG.el("p", { clase: "cifra-valor" }, c.valor, c.unidad ? NG.el("small", { texto: c.unidad }) : null),
        c.nota ? NG.el("p", { clase: "cifra-nota", texto: c.nota }) : null)));
  };

  const ORIGEN_TXT = { FISICO: "Físico", SIMULADO: "Simulado", CALCULADO: "Calculado", PRUEBA: "Prueba" };
  NG.etiquetaOrigen = function (codigo) {
    if (!codigo) return NG.el("span", { clase: "nulo", texto: "—" });
    const c = String(codigo).toUpperCase();
    return NG.el("span", { clase: "etiqueta " + c.toLowerCase(), texto: ORIGEN_TXT[c] || c });
  };
  NG.etiqueta = function (texto, tipo) { return NG.el("span", { clase: "etiqueta " + (tipo || "neutra"), texto: texto }); };

  NG.aviso = function (texto, error) { return NG.el("div", { clase: "aviso" + (error ? " error" : ""), role: error ? "alert" : "note" }, texto); };

  // Tabla de datos. columnas: [{clave, titulo, num, formato(v, fila), nodo(v, fila)}]
  NG.tabla = function (columnas, filas, opciones) {
    const op = opciones || {};
    const thead = NG.el("thead", null, NG.el("tr", null, columnas.map((c) => {
      const th = NG.el("th", { clase: c.num ? "num" : null, scope: "col" });
      if (op.ordenar && c.ordenable !== false) {
        const activo = op.orden === c.clave;
        th.setAttribute("aria-sort", activo ? (op.dir === "desc" ? "descending" : "ascending") : "none");
        th.append(NG.el("button", { type: "button", onclick: () => op.ordenar(c.clave) }, c.titulo, activo ? (op.dir === "desc" ? " ↓" : " ↑") : ""));
      } else th.textContent = c.titulo;
      return th;
    })));
    const tbody = NG.el("tbody");
    if (!filas.length) {
      tbody.append(NG.el("tr", null, NG.el("td", { colspan: columnas.length, clase: "nulo", texto: op.vacio || "Sin datos para este filtro." })));
    }
    filas.forEach((f, i) => {
      const tr = NG.el("tr", { clase: (op.alClic ? "clicable" : "") + (op.seleccion !== undefined && op.seleccion === op.clave?.(f) ? " seleccionada" : "") });
      if (op.alClic) {
        tr.tabIndex = 0;
        tr.addEventListener("click", () => op.alClic(f, i));
        tr.addEventListener("keydown", (e) => { if (e.key === "Enter") op.alClic(f, i); });
      }
      columnas.forEach((c) => {
        const v = Array.isArray(f) ? f[c.indice] : f[c.clave];
        const td = NG.el("td", { clase: c.num ? "num" : null });
        if (c.nodo) td.append(c.nodo(v, f));
        else if (v === null || v === undefined) { td.className += " nulo"; td.textContent = op.textoNulo || "—"; }
        else td.textContent = c.formato ? c.formato(v, f) : String(v);
        tr.append(td);
      });
      tbody.append(tr);
    });
    return NG.el("div", { clase: "tabla-envoltura" + (op.alta ? " tabla-alta" : "") }, NG.el("table", { clase: "datos" }, thead, tbody));
  };

  NG.paginador = function (pagina, tam, total, alCambiar) {
    const paginas = total ? Math.max(1, Math.ceil(total / tam)) : null;
    const entrada = NG.el("input", { type: "number", min: 1, max: paginas || undefined, value: pagina, "aria-label": "Ir a la página" });
    entrada.addEventListener("change", () => { const n = parseInt(entrada.value, 10); if (n >= 1) alCambiar(paginas ? Math.min(n, paginas) : n); });
    const desde = (pagina - 1) * tam + 1;
    return NG.el("div", { clase: "paginador" },
      NG.el("button", { type: "button", clase: "boton", disabled: pagina <= 1, onclick: () => alCambiar(1) }, "Primera"),
      NG.el("button", { type: "button", clase: "boton", disabled: pagina <= 1, onclick: () => alCambiar(pagina - 1) }, "Anterior"),
      NG.el("span", null, "Página "), entrada, NG.el("span", { texto: paginas ? " de " + NG.fmt.num(paginas) : "" }),
      NG.el("button", { type: "button", clase: "boton", disabled: paginas !== null && pagina >= paginas, onclick: () => alCambiar(pagina + 1) }, "Siguiente"),
      paginas ? NG.el("button", { type: "button", clase: "boton", disabled: pagina >= paginas, onclick: () => alCambiar(paginas) }, "Última") : null,
      NG.el("span", { texto: total !== null && total !== undefined
        ? "Filas " + NG.fmt.num(desde) + "–" + NG.fmt.num(Math.min(desde + tam - 1, total)) + " de " + NG.fmt.num(total)
        : "Total no calculado (consulta muy costosa sin índice)" }));
  };

  // ------------------------------------------------------------------ tooltip único
  const tt = () => document.getElementById("tooltip");
  NG.tooltip = {
    mostrar: function (x, y, titulo, filas) {
      const caja = tt();
      NG.vaciar(caja);
      if (titulo) caja.append(NG.el("div", { clase: "tt-titulo", texto: titulo }));
      (filas || []).forEach((f) => {
        caja.append(NG.el("div", { clase: "tt-fila" },
          f.color ? NG.el("span", { clase: "tt-clave", estilo: "background:" + f.color }) : null,
          NG.el("strong", { texto: f.valor }), f.etiqueta ? NG.el("span", { texto: f.etiqueta }) : null));
      });
      caja.hidden = false;
      const r = caja.getBoundingClientRect();
      let px = x + 14, py = y + 14;
      if (px + r.width > window.innerWidth - 8) px = x - r.width - 14;
      if (py + r.height > window.innerHeight - 8) py = y - r.height - 14;
      caja.style.left = Math.max(8, px) + "px";
      caja.style.top = Math.max(8, py) + "px";
    },
    ocultar: function () { const caja = tt(); if (caja) caja.hidden = true; },
  };

  NG.color = function (variable) {
    return getComputedStyle(document.documentElement).getPropertyValue(variable).trim() || "#888";
  };
  NG.SERIES = ["--s1", "--s2", "--s3", "--s4", "--s5", "--s6"];

  NG.tkFecha = (tk) => { const s = String(tk); return s.slice(0, 4) + "-" + s.slice(4, 6) + "-" + s.slice(6, 8); };
  NG.descargarCSV = function (nombre, columnas, filas) {
    const esc = (v) => { const s = v === null || v === undefined ? "" : String(v); return /[",;\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const texto = [columnas.map(esc).join(";")].concat(filas.map((f) => f.map(esc).join(";"))).join("\n");
    const url = URL.createObjectURL(new Blob(["﻿" + texto], { type: "text/csv;charset=utf-8" }));
    const a = NG.el("a", { href: url, download: nombre });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  };
})();
