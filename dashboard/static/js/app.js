/* NeoGrid · arranque: filtros globales, rutas (#/vista), tema y menú. */
(function () {
  "use strict";
  const NG = window.NG;
  const $ = (id) => document.getElementById(id);
  const CLAVE_FILTROS = "neogrid.filtros", CLAVE_TEMA = "neogrid.tema";

  function guardarLocal(clave, valor) { try { localStorage.setItem(clave, JSON.stringify(valor)); } catch (e) { /* almacenamiento no disponible */ } }
  function leerLocal(clave) { try { return JSON.parse(localStorage.getItem(clave) || "null"); } catch (e) { return null; } }

  // ------------------------------------------------------------------ tema
  function aplicarTema(t) { if (t) document.documentElement.setAttribute("data-tema", t); else document.documentElement.removeAttribute("data-tema"); }
  aplicarTema(leerLocal(CLAVE_TEMA));
  function temaActual() {
    const t = document.documentElement.getAttribute("data-tema");
    if (t) return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "oscuro" : "claro";
  }

  // ------------------------------------------------------------------ filtros
  function sumarDias(fecha, n) { const d = new Date(fecha + "T12:00:00"); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); }
  function leerFiltros() {
    const ext = NG.estado.catalogos.extension;
    const periodo = $("f-periodo").value;
    let desde = "", hasta = "";
    if (periodo === "personalizado") { desde = $("f-desde").value; hasta = $("f-hasta").value; }
    else if (periodo === "mes") { hasta = ext.hasta; desde = ext.hasta.slice(0, 8) + "01"; }
    else if (periodo !== "todo") { hasta = ext.hasta; desde = sumarDias(ext.hasta, -(parseInt(periodo, 10) - 1)); }
    NG.estado.filtros = { periodo, desde, hasta, ubicacion: $("f-ubicacion").value, luminaria: $("f-luminaria").value, origen: $("f-origen").value };
    $("filtros").classList.toggle("sin-fechas", periodo !== "personalizado");
    if (periodo !== "personalizado") { $("f-desde").value = desde || ext.desde; $("f-hasta").value = hasta || ext.hasta; }
    guardarLocal(CLAVE_FILTROS, NG.estado.filtros);
  }

  function prepararFiltros() {
    const cat = NG.estado.catalogos;
    const ext = cat.extension;
    ["f-desde", "f-hasta"].forEach((id) => { $(id).min = ext.desde; $(id).max = ext.hasta; });
    const sel = $("f-ubicacion");
    const gZ = NG.el("optgroup", { label: "Zonas" }, cat.zonas.map((z) => NG.el("option", { value: "z:" + z.codigo }, z.nombre)));
    const gU = NG.el("optgroup", { label: "Tramos" }, cat.ubicaciones.map((u) => NG.el("option", { value: "u:" + u.ubicacion_id }, u.codigo + " · " + u.nombre)));
    sel.append(gZ, gU);
    const lum = $("f-luminaria");
    const porZona = {};
    cat.luminarias.forEach((l) => (porZona[l.zona] = porZona[l.zona] || []).push(l));
    Object.entries(porZona).forEach(([z, ls]) => lum.append(NG.el("optgroup", { label: (cat.zonas.find((x) => x.codigo === z) || {}).nombre || z },
      ls.map((l) => NG.el("option", { value: l.luminaria_id }, l.codigo + (l.es_fisica ? " (maqueta)" : ""))))));
    const previo = leerLocal(CLAVE_FILTROS);
    if (previo) {
      $("f-periodo").value = previo.periodo || "todo";
      if (previo.periodo === "personalizado") { $("f-desde").value = previo.desde || ""; $("f-hasta").value = previo.hasta || ""; }
      $("f-ubicacion").value = previo.ubicacion || "";
      $("f-luminaria").value = previo.luminaria || "";
      $("f-origen").value = previo.origen || "";
    }
    leerFiltros();
    ["f-periodo", "f-desde", "f-hasta", "f-ubicacion", "f-luminaria", "f-origen"].forEach((id) =>
      $(id).addEventListener("change", () => { leerFiltros(); NG.recargar(); }));
    $("f-limpiar").addEventListener("click", () => {
      $("f-periodo").value = "todo"; $("f-ubicacion").value = ""; $("f-luminaria").value = ""; $("f-origen").value = "";
      leerFiltros(); NG.recargar();
    });
  }

  // ------------------------------------------------------------------ rutas
  let vistaActual = null;
  function rutaActual() {
    const h = location.hash.replace(/^#\/?/, "");
    const [nombre, consulta] = h.split("?");
    return { nombre: NG.vistas[nombre] ? nombre : "general", params: new URLSearchParams(consulta || "") };
  }

  async function mostrar(conservarMarco) {
    const { nombre, params } = rutaActual();
    const vista = NG.vistas[nombre];
    if (NG.estado.controlador) NG.estado.controlador.abort();
    NG.estado.controlador = new AbortController();
    if (vistaActual && vistaActual.salir) vistaActual.salir();
    vistaActual = vista;
    NG.tooltip.ocultar();
    document.querySelectorAll(".navegacion a").forEach((a) => {
      if (a.dataset.vista === nombre) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    });
    document.title = vista.titulo + " · NeoGrid";
    $("filtros").hidden = !!vista.sinFiltros;
    $("navegacion").classList.remove("abierta");
    $("boton-menu").setAttribute("aria-expanded", "false");

    const viejo = $("contenido");
    const nuevo = NG.el("main", { id: "contenido-nuevo", clase: "contenido", tabindex: "-1" });
    if (conservarMarco) {
      viejo.classList.add("recargando");
      nuevo.style.cssText = `position:absolute;visibility:hidden;left:0;top:0;width:${viejo.clientWidth}px`;
      viejo.parentNode.style.position = "relative";
      viejo.after(nuevo);
    } else {
      NG.vaciar(viejo);
      viejo.append(NG.el("p", { clase: "cargando", texto: "Cargando…" }));
      nuevo.style.cssText = `position:absolute;visibility:hidden;left:0;top:0;width:${viejo.clientWidth}px`;
      viejo.parentNode.style.position = "relative";
      viejo.after(nuevo);
    }
    const controlador = NG.estado.controlador;
    try {
      await vista.render(nuevo, params);
    } catch (e) {
      if (e.name === "AbortError" || controlador.signal.aborted) { nuevo.remove(); return; }
      NG.vaciar(nuevo);
      nuevo.append(NG.encabezado(vista.titulo));
      if (e.estado === 503 && /No se encontr|No se pudo conectar/.test(e.message)) {
        nuevo.append(NG.aviso("El tablero no encuentra los datos. " + e.message, true),
          NG.el("p", { clase: "nota", texto: "En la nube: defina DATOS_URL con el enlace de neogrid_datos.zip y vuelva a desplegar. En local: ejecute scripts/exportar_a_sqlite.py o use MODO_BD=mssql." }));
      } else nuevo.append(NG.aviso(e.message || "No se pudo cargar la vista.", true));
    }
    if (controlador.signal.aborted) { nuevo.remove(); return; }
    viejo.remove();
    nuevo.id = "contenido";
    nuevo.style.cssText = "";
    if (!conservarMarco) { window.scrollTo(0, 0); }
  }
  NG.recargar = () => mostrar(true);

  // ------------------------------------------------------------------ arranque
  async function iniciar() {
    $("boton-tema").addEventListener("click", () => {
      const nuevo = temaActual() === "oscuro" ? "claro" : "oscuro";
      aplicarTema(nuevo); guardarLocal(CLAVE_TEMA, nuevo); NG.recargar();
    });
    $("boton-menu").addEventListener("click", () => {
      const abierta = $("navegacion").classList.toggle("abierta");
      $("boton-menu").setAttribute("aria-expanded", String(abierta));
    });
    try {
      const meta = await NG.api("meta/info", null, { signal: undefined });
      NG.estado.meta = meta;
      NG.estado.catalogos = meta.catalogos;
      const m = meta.motor || {};
      $("fuente-datos").textContent = meta.modo === "sqlite"
        ? "Copia de SQL Server exportada el " + NG.fmt.fechaHora(m.fecha_exportacion) + " · datos " + NG.fmt.fecha(meta.catalogos.extension.desde) + " a " + NG.fmt.fecha(meta.catalogos.extension.hasta)
        : "Conectado a SQL Server en vivo" + (m.servidor ? " · " + m.servidor : "");
      $("pie-texto").textContent = "NeoGrid · alumbrado público inteligente · versión " + meta.version + " · " + (m.motor || "") + ".";
      prepararFiltros();
    } catch (e) {
      $("fuente-datos").textContent = "Sin datos";
      NG.estado.catalogos = { zonas: [], ubicaciones: [], luminarias: [], extension: { desde: "2026-05-01", hasta: "2026-10-10" } };
      const c = $("contenido");
      NG.vaciar(c);
      c.append(NG.encabezado("NeoGrid · Alumbrado"), NG.aviso("No se pudieron cargar los datos: " + e.message, true),
        NG.el("p", { clase: "nota", texto: "Si es un despliegue nuevo, revise la variable DATOS_URL y el registro de compilación. Si el servidor estaba dormido (plan gratuito), recargue la página en un minuto." }));
      return;
    }
    window.addEventListener("hashchange", () => mostrar(false));
    mostrar(false);
  }
  document.addEventListener("DOMContentLoaded", iniciar);
})();
