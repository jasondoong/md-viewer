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

    let scale = 1, panX = 0, panY = 0;

    function apply() {
      svg.style.transformOrigin = "0 0";
      svg.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
    }

    function reset() {
      scale = 1; panX = 0; panY = 0;
      apply();
    }

    // Shift + wheel: zoom centered on cursor
    container.addEventListener("wheel", (e) => {
      if (!e.shiftKey) return;
      e.preventDefault();
      const rect = container.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      const old = scale;
      const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
      scale = Math.max(0.1, Math.min(10, scale * factor));
      panX = cx - (cx - panX) * (scale / old);
      panY = cy - (cy - panY) * (scale / old);
      apply();
    }, { passive: false });

    // Drag to pan
    container.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      const sx = e.clientX, sy = e.clientY;
      const spx = panX, spy = panY;
      container.classList.add("mermaid-panning");

      function onMove(ev) {
        panX = spx + (ev.clientX - sx);
        panY = spy + (ev.clientY - sy);
        apply();
      }
      function onUp() {
        container.classList.remove("mermaid-panning");
        window.removeEventListener("mousemove", onMove);
        window.removeEventListener("mouseup", onUp);
      }
      window.addEventListener("mousemove", onMove);
      window.addEventListener("mouseup", onUp);
    });

    // Double-click to reset zoom & pan
    container.addEventListener("dblclick", reset);
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

    // Used by the Windows host (macOS uses WKWebView.pageZoom instead).
    setZoom(factor) {
      document.documentElement.style.zoom = String(factor);
    },
  };

  function renderDocument(payload, resetScroll) {
    const generation = ++renderGeneration;

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
