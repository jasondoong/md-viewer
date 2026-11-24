(function () {
  "use strict";

  const content = document.getElementById("content");
  const baseEl = document.getElementById("doc-base");

  marked.use({ gfm: true, breaks: false });

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const isDark = () => darkQuery.matches;

  let mermaidReady = null;
  if (window.mermaid) {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: isDark() ? "dark" : "default" });
    mermaidReady = !!window.mermaid;
  }

  let lastPayload = null;
  let activeDiagram = null;
  const controls = document.createElement("div");
  controls.className = "mermaid-controls";
  controls.hidden = true;
  for (const [label, title, action] of [
    ["+", "Zoom in", "in"], ["−", "Zoom out", "out"], ["↺", "Reset", "reset"]
  ]) {
    const button = document.createElement("button");
    button.textContent = label;
    button.title = title;
    button.setAttribute("aria-label", title);
    button.addEventListener("click", () => {
      if (!activeDiagram) return;
      if (action === "reset") activeDiagram._resetMermaid();
      else activeDiagram._zoomMermaid(action === "in" ? 1 : -1);
    });
    controls.appendChild(button);
  }
  document.body.appendChild(controls);

  // Bumped on every renderDocument; stale in-flight Mermaid loops compare against
  // this to abort so a rapid document/theme change can't paint outdated output.
  let renderGeneration = 0;

  // Monotonic counter for Mermaid render IDs (independent of Date.now).
  let mermaidIdSeq = 0;

  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s+/g, "-");
  }

  function escapeHTML(s) {
    return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  // Split off YAML front matter so it doesn't render as a <hr> + paragraph.
  function splitFrontMatter(md) {
    const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/);
    if (!m) return { frontMatter: null, body: md };
    return { frontMatter: m[1], body: md.slice(m[0].length) };
  }

  function addHeadingIDs(root) {
    const used = Object.create(null);
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
      let slug = slugify(h.textContent) || "section";
      if (slug in used) {
        used[slug] += 1;
        slug = slug + "-" + used[slug];
      } else {
        used[slug] = 0;
      }
      h.id = slug;
    });
  }

  function highlight(root) {
    root.querySelectorAll("pre code").forEach((el) => {
      if (el.classList.contains("language-mermaid")) return;
      try { hljs.highlightElement(el); } catch (e) { /* unknown language etc. */ }
    });
  }

  function setupMermaidInteraction(container) {
    const svg = container.querySelector("svg");
    if (!svg) return;

    const viewport = document.createElement("div");
    viewport.className = "mermaid-viewport";
    container.insertBefore(viewport, svg);
    viewport.appendChild(svg);

    // Capture the fitted size before allowing the diagram to grow beyond its viewport.
    const naturalWidth = parseFloat(svg.style.maxWidth) || svg.getBoundingClientRect().width;
    const aspect = svg.viewBox.baseVal.height / svg.viewBox.baseVal.width || 1;
    let scale = 1;
    function apply() {
      const width = Math.min(naturalWidth, viewport.clientWidth) * scale;
      svg.style.width = `${width}px`;
      svg.style.height = `${width * aspect}px`;
    }
    function zoom(steps, cx) {
      const rect = viewport.getBoundingClientRect();
      const anchor = cx === undefined ? rect.width / 2 : cx - rect.left;
      const old = scale;
      scale = Math.max(0.1, Math.min(10, scale * Math.pow(1.15, steps)));
      const offset = viewport.scrollLeft + anchor;
      apply();
      viewport.scrollLeft = offset * scale / old - anchor;
    }
    function reset() {
      scale = 1;
      apply();
      viewport.scrollLeft = 0;
      viewport.scrollTop = 0;
    }
    container._zoomMermaid = zoom;

    container._resetMermaid = reset;
    if (!activeDiagram) activeDiagram = container;
    controls.hidden = false;
    viewport.addEventListener("pointerenter", () => { activeDiagram = container; });
    viewport.addEventListener("pointerdown", () => { activeDiagram = container; });
    apply();
    new ResizeObserver(apply).observe(viewport);

    // Other hosts may deliver Ctrl-wheel directly to the page.
    viewport.addEventListener("wheel", (e) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      zoom(e.deltaY < 0 ? 1 : -1, e.clientX);
    }, { passive: false });

    let panning = false, startX = 0, startY = 0, startScroll = 0, startScrollY = 0;
    viewport.addEventListener("pointerdown", (e) => {
      if (e.button !== 0 || e.target !== viewport) return;
      e.preventDefault();
      panning = true;
      startX = e.clientX;
      startY = e.clientY;
      startScroll = viewport.scrollLeft;
      startScrollY = viewport.scrollTop;
      viewport.classList.add("mermaid-panning");
      viewport.setPointerCapture(e.pointerId);
    });
    viewport.addEventListener("pointermove", (e) => {
      if (!panning) return;
      viewport.scrollLeft = startScroll - (e.clientX - startX);
      viewport.scrollTop = startScrollY - (e.clientY - startY);
    });
    function endPan() {
      panning = false;
      viewport.classList.remove("mermaid-panning");
    }
    viewport.addEventListener("pointerup", endPan);
    viewport.addEventListener("pointercancel", endPan);
    viewport.addEventListener("dblclick", reset);

  }

  async function renderMermaid(root, generation) {
    if (!mermaidReady) return;
    const blocks = Array.from(root.querySelectorAll("pre code.language-mermaid"));
    if (!blocks.length) return;
    for (const code of blocks) {
      // Abort if a newer render has superseded this one before we await.
      if (generation !== renderGeneration) return;
      const pre = code.parentElement;
      const id = "mermaid-" + (++mermaidIdSeq); // unique per render
      try {
        const { svg } = await mermaid.render(id, code.textContent);
        // Abort if a newer render superseded us while we were awaiting.
        if (generation !== renderGeneration) return;
        const wrap = document.createElement("div");
        wrap.className = "mermaid";
        wrap.innerHTML = svg;
        pre.replaceWith(wrap);
        setupMermaidInteraction(wrap);
      } catch (e) {
        // Keep the original source visible; surface a readable Mermaid error above it.
        const errEl = document.createElement("div");
        errEl.className = "mermaid-error";
        const msg = (e && (e.message || e.str)) || String(e);
        errEl.textContent = "Mermaid error: " + msg;
        // Mermaid may have left a temporary element in the DOM; remove it.
        const leftover = document.getElementById(id);
        if (leftover && leftover.parentNode) leftover.parentNode.removeChild(leftover);
        if (pre.parentNode) pre.parentNode.insertBefore(errEl, pre);
      }
    }
  }

  window.MDP = {
    render(payload) {
      lastPayload = payload;
      renderDocument(payload, payload.resetScroll);
    },

    // Re-render the currently displayed document (used on theme change) without
    // resetting the scroll position.
    reRender() {
      if (lastPayload) renderDocument(lastPayload, false);
    },

    zoomMermaidAt(x, y, steps) {
      const element = document.elementFromPoint(x, y);
      const diagram = element && (element.closest(".mermaid") || (controls.contains(element) && activeDiagram));
      if (!diagram || !diagram._zoomMermaid) return false;
      activeDiagram = diagram;
      diagram._zoomMermaid(steps, controls.contains(element) ? undefined : x);
      return true;
    },

    setControlScale(factor) {
      controls.style.setProperty("--page-zoom", String(factor));
    },

    // Used by the Windows host (macOS uses WKWebView.pageZoom instead).
    setZoom(factor) {
      document.documentElement.style.zoom = String(factor);
      this.setControlScale(factor);
    },
  };

  function renderDocument(payload, resetScroll) {
    const generation = ++renderGeneration;
    activeDiagram = null;
    controls.hidden = true;

    if (payload.base) baseEl.setAttribute("href", payload.base);

    const { frontMatter, body } = splitFrontMatter(payload.markdown || "");
    let html = "";
    if (frontMatter !== null) {
      html += '<details class="front-matter"><summary>Front matter</summary><pre><code class="language-yaml">' +
        escapeHTML(frontMatter) + "</code></pre></details>";
    }
    html += marked.parse(body);
    content.innerHTML = html;

    addHeadingIDs(content);
    highlight(content);
    renderMermaid(content, generation);

    if (resetScroll) window.scrollTo(0, 0);
  }

  // Re-render the current document when the system switches light/dark so the
  // Mermaid theme can be updated, keeping the current scroll position.
  darkQuery.addEventListener("change", () => {
    if (!mermaidReady || !lastPayload) return;
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: isDark() ? "dark" : "default" });
    window.MDP.reRender();
  });

  // Windows only: a focused WebView2 swallows keystrokes, so forward app shortcuts to the host.
  if (window.chrome && window.chrome.webview) {
    document.addEventListener("keydown", (e) => {
      const isShortcut = e.ctrlKey || e.altKey || e.key === "F5" || e.key === "Escape";
      if (!isShortcut) return;
      // Leave copy / select-all / find to the browser.
      if (e.ctrlKey && !e.altKey && !e.shiftKey && ["c", "a", "f"].includes(e.key.toLowerCase())) return;
      e.preventDefault();
      window.chrome.webview.postMessage({ type: "key", key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey });
    });
  }

  // All link clicks go to the native side; in-page anchors are handled here.
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a");
    if (!a) return;
    const raw = a.getAttribute("href");
    if (!raw) return;
    e.preventDefault();

    if (raw.startsWith("#")) {
      let id = raw.slice(1);
      try { id = decodeURIComponent(id); } catch (err) { /* malformed %-escape */ }
      const target = document.getElementById(id) || document.getElementById(slugify(id));
      if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    postLink(a.href);
  });

  // Native bridge: WKWebView on macOS, WebView2 on Windows.
  function postLink(href) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.linkClicked) {
      window.webkit.messageHandlers.linkClicked.postMessage(href);
    } else if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage({ type: "link", href: href });
    }
  }
})();
