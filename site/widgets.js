// Scarf dashboard widget renderer — the dogfood piece.
//
// Takes the SAME `dashboard.json` shape the Scarf macOS app renders
// (see scarf/scarf/Core/Models/ProjectDashboard.swift) and produces an
// HTML approximation for the catalog site. A template's detail page
// shows a live preview of exactly what the user's project dashboard
// will look like after install.
//
// Widget types mirrored from the Swift dispatcher:
//   stat      — big number + label + icon + color
//   progress  — label + 0..1 bar
//   text      — markdown (tiny subset renderer)
//   table     — plain HTML table
//   list      — bulleted list with optional status badge
//   chart     — SVG line/bar by series
//   webview   — sandboxed <iframe>
//
// Vanilla JS, no build step, no external deps. ~300 lines.

(function (global) {
  "use strict";

  const SF_SYMBOL_FALLBACK = "●"; // SF Symbols aren't available on the web — use a dot.

  // ---------------------------------------------------------------------
  // Entry point
  // ---------------------------------------------------------------------

  /**
   * Render a ProjectDashboard JSON into `container`.
   * @param {HTMLElement} container
   * @param {object} dashboard
   */
  function renderDashboard(container, dashboard) {
    container.innerHTML = "";
    if (!dashboard || !Array.isArray(dashboard.sections)) {
      container.appendChild(elt("div", "dashboard-error", "Could not render dashboard."));
      return;
    }
    const root = elt("div", "dashboard");
    if (dashboard.title) {
      const header = elt("div", "dashboard-header");
      header.appendChild(elt("h1", "dashboard-title", dashboard.title));
      if (dashboard.description) {
        header.appendChild(elt("p", "dashboard-desc", dashboard.description));
      }
      root.appendChild(header);
    }
    for (const section of dashboard.sections) {
      root.appendChild(renderSection(section));
    }
    container.appendChild(root);
  }

  function renderSection(section) {
    const wrap = elt("section", "dashboard-section");
    if (section.title) {
      wrap.appendChild(elt("h2", "section-title", section.title));
    }
    const cols = Math.max(1, Math.min(6, section.columns || 3));
    const grid = elt("div", "widget-grid");
    grid.style.setProperty("--cols", String(cols));
    // Webview widgets render in a dedicated tab in the Scarf app but
    // we inline them here so the catalog preview is single-scroll.
    for (const widget of section.widgets || []) {
      grid.appendChild(renderWidget(widget));
    }
    wrap.appendChild(grid);
    return wrap;
  }

  function renderWidget(widget) {
    try {
      switch (widget.type) {
        case "stat":     return renderStat(widget);
        case "progress": return renderProgress(widget);
        case "text":     return renderText(widget);
        case "table":    return renderTable(widget);
        case "list":     return renderList(widget);
        case "chart":    return renderChart(widget);
        case "webview":  return renderWebview(widget);
        default:         return renderUnknown(widget);
      }
    } catch (e) {
      console.error("widget render error", widget, e);
      return renderUnknown({ ...widget, title: (widget.title || "") + " (render error)" });
    }
  }

  // ---------------------------------------------------------------------
  // Stat
  // ---------------------------------------------------------------------

  function renderStat(widget) {
    const card = elt("div", "widget widget-stat");
    card.dataset.color = widget.color || "blue";
    const top = elt("div", "widget-stat-top");
    top.appendChild(elt("span", "widget-stat-icon", SF_SYMBOL_FALLBACK));
    top.appendChild(elt("span", "widget-title", widget.title || ""));
    card.appendChild(top);
    const value = elt("div", "widget-stat-value", displayValue(widget.value));
    card.appendChild(value);
    if (widget.subtitle) {
      card.appendChild(elt("div", "widget-stat-subtitle", widget.subtitle));
    }
    return card;
  }

  function displayValue(v) {
    if (v === null || v === undefined) return "—";
    if (typeof v === "number") {
      return Number.isInteger(v) ? v.toLocaleString() : v.toFixed(1);
    }
    return String(v);
  }

  // ---------------------------------------------------------------------
  // Progress
  // ---------------------------------------------------------------------

  function renderProgress(widget) {
    const card = elt("div", "widget widget-progress");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    if (widget.label) {
      card.appendChild(elt("div", "widget-progress-label", widget.label));
    }
    const bar = elt("div", "progress-bar");
    const fill = elt("div", "progress-fill");
    const pct = Math.max(0, Math.min(1, Number(widget.value) || 0));
    fill.style.width = (pct * 100).toFixed(1) + "%";
    bar.appendChild(fill);
    card.appendChild(bar);
    return card;
  }

  // ---------------------------------------------------------------------
  // Text (markdown)
  // ---------------------------------------------------------------------

  function renderText(widget) {
    const card = elt("div", "widget widget-text");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    const body = elt("div", "widget-text-body");
    if ((widget.format || "").toLowerCase() === "markdown") {
      body.innerHTML = renderMarkdown(widget.content || "");
    } else {
      body.textContent = widget.content || "";
    }
    card.appendChild(body);
    return card;
  }

  /** Minimal markdown subset: headings, bold, italic, inline code, code
   * blocks, bullet/numbered lists, links, paragraphs. Deliberately tiny
   * — the catalog showcases dashboards, not blog posts. */
  function renderMarkdown(src) {
    const lines = src.split(/\r?\n/);
    let html = "";
    let inCode = false;
    let inList = null; // "ul" | "ol" | null
    const flushList = () => {
      if (inList) {
        html += `</${inList}>`;
        inList = null;
      }
    };
    for (const rawLine of lines) {
      const line = rawLine;
      if (line.trim().startsWith("```")) {
        flushList();
        if (inCode) {
          html += "</code></pre>";
          inCode = false;
        } else {
          html += "<pre><code>";
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        html += escapeHTML(line) + "\n";
        continue;
      }
      if (/^#{1,6}\s/.test(line)) {
        flushList();
        const level = Math.min(6, (line.match(/^#+/) || ["#"])[0].length);
        const text = line.replace(/^#+\s*/, "");
        html += `<h${level}>${renderInline(text)}</h${level}>`;
        continue;
      }
      const bulletMatch = line.match(/^\s*[-*]\s+(.*)$/);
      const orderedMatch = line.match(/^\s*\d+\.\s+(.*)$/);
      if (bulletMatch) {
        if (inList !== "ul") { flushList(); html += "<ul>"; inList = "ul"; }
        html += `<li>${renderInline(bulletMatch[1])}</li>`;
        continue;
      }
      if (orderedMatch) {
        if (inList !== "ol") { flushList(); html += "<ol>"; inList = "ol"; }
        html += `<li>${renderInline(orderedMatch[1])}</li>`;
        continue;
      }
      if (line.trim() === "") {
        flushList();
        continue;
      }
      flushList();
      html += `<p>${renderInline(line)}</p>`;
    }
    flushList();
    if (inCode) html += "</code></pre>";
    return html;
  }

  function renderInline(text) {
    // Escape first, then re-apply formatting on the escaped text.
    let s = escapeHTML(text);
    // Inline code before bold/italic so the markers inside `…` stay literal.
    s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^\w])\*([^*]+)\*/g, "$1<em>$2</em>");
    s = s.replace(/(^|[^\w])_([^_]+)_/g, "$1<em>$2</em>");
    // Links: [text](url)
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, text, url) => {
      return `<a href="${url}">${text}</a>`;
    });
    return s;
  }

  // ---------------------------------------------------------------------
  // Table
  // ---------------------------------------------------------------------

  function renderTable(widget) {
    const card = elt("div", "widget widget-table");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    const table = elt("table", "data-table");
    if (Array.isArray(widget.columns)) {
      const thead = elt("thead");
      const tr = elt("tr");
      for (const col of widget.columns) {
        tr.appendChild(elt("th", null, col));
      }
      thead.appendChild(tr);
      table.appendChild(thead);
    }
    if (Array.isArray(widget.rows)) {
      const tbody = elt("tbody");
      for (const row of widget.rows) {
        const tr = elt("tr");
        for (const cell of row) {
          tr.appendChild(elt("td", null, cell));
        }
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
    }
    card.appendChild(table);
    return card;
  }

  // ---------------------------------------------------------------------
  // List
  // ---------------------------------------------------------------------

  function renderList(widget) {
    const card = elt("div", "widget widget-list");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    const ul = elt("ul", "widget-list-items");
    for (const item of widget.items || []) {
      const li = elt("li", "widget-list-item");
      li.appendChild(elt("span", "widget-list-text", item.text || ""));
      if (item.status) {
        const badge = elt("span", "widget-list-status", item.status);
        badge.dataset.status = item.status;
        li.appendChild(badge);
      }
      ul.appendChild(li);
    }
    card.appendChild(ul);
    return card;
  }

  // ---------------------------------------------------------------------
  // Chart (SVG — no Chart.js dep)
  // ---------------------------------------------------------------------

  function renderChart(widget) {
    const card = elt("div", "widget widget-chart");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    const series = widget.series || [];
    if (series.length === 0) {
      card.appendChild(elt("div", "widget-chart-empty", "No chart data."));
      return card;
    }
    // Collect x-labels (assume aligned across series).
    const xs = series[0].data.map((p) => p.x);
    const ys = series.flatMap((s) => s.data.map((p) => p.y));
    const maxY = Math.max(0, ...ys);
    const minY = Math.min(0, ...ys);
    const W = 320;
    const H = 120;
    const padL = 24, padR = 8, padT = 8, padB = 22;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    svg.classList.add("widget-chart-svg");

    const yToPixel = (y) => {
      if (maxY === minY) return padT + plotH / 2;
      return padT + plotH - ((y - minY) / (maxY - minY)) * plotH;
    };
    const xToPixel = (i) => padL + (plotW * (i / Math.max(1, xs.length - 1)));

    // Axis baseline
    const axis = document.createElementNS(svgNS, "line");
    axis.setAttribute("x1", String(padL));
    axis.setAttribute("y1", String(padT + plotH));
    axis.setAttribute("x2", String(W - padR));
    axis.setAttribute("y2", String(padT + plotH));
    axis.setAttribute("class", "chart-axis");
    svg.appendChild(axis);

    const kind = (widget.chartType || "line").toLowerCase();
    series.forEach((s, idx) => {
      const color = s.color || ["accent", "red", "blue", "orange"][idx % 4];
      if (kind === "bar") {
        const barW = Math.max(2, plotW / (xs.length * series.length) - 2);
        s.data.forEach((p, i) => {
          const rect = document.createElementNS(svgNS, "rect");
          const x = xToPixel(i) - barW / 2 + idx * barW;
          const y = yToPixel(p.y);
          rect.setAttribute("x", String(x));
          rect.setAttribute("y", String(y));
          rect.setAttribute("width", String(barW));
          rect.setAttribute("height", String(padT + plotH - y));
          rect.setAttribute("class", "chart-bar");
          rect.dataset.color = color;
          svg.appendChild(rect);
        });
      } else {
        const d = s.data.map((p, i) => {
          const x = xToPixel(i);
          const y = yToPixel(p.y);
          return `${i === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`;
        }).join(" ");
        const path = document.createElementNS(svgNS, "path");
        path.setAttribute("d", d);
        path.setAttribute("class", "chart-line");
        path.dataset.color = color;
        svg.appendChild(path);
      }
    });

    card.appendChild(svg);
    return card;
  }

  // ---------------------------------------------------------------------
  // Webview
  // ---------------------------------------------------------------------

  function renderWebview(widget) {
    const card = elt("div", "widget widget-webview");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    const frame = document.createElement("iframe");
    frame.src = widget.url || "about:blank";
    frame.setAttribute("sandbox", "allow-scripts allow-popups allow-forms");
    frame.style.width = "100%";
    frame.style.height = (widget.height ? Number(widget.height) : 300) + "px";
    frame.loading = "lazy";
    card.appendChild(frame);
    return card;
  }

  // ---------------------------------------------------------------------
  // Unknown / placeholder
  // ---------------------------------------------------------------------

  function renderUnknown(widget) {
    const card = elt("div", "widget widget-unknown");
    card.appendChild(elt("div", "widget-title", widget.title || ""));
    card.appendChild(elt("div", "widget-unknown-body",
      `Unknown widget type: ${widget.type}`));
    return card;
  }

  // ---------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------

  function elt(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

  global.ScarfWidgets = {
    renderDashboard,
    renderMarkdown,   // exposed for the template detail page's README block
  };
})(typeof window !== "undefined" ? window : this);
