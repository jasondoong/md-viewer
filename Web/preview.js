(function () {
  "use strict";

  const content = document.getElementById("content");
  const baseEl = document.getElementById("doc-base");

  marked.use({ gfm: true, breaks: false });

  let mermaidReady = null;
  if (window.mermaid) {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });
    mermaidReady = !!window.mermaid;
  }

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

  async function renderMermaid(root) {
    if (!mermaidReady) return;
    const blocks = Array.from(root.querySelectorAll("pre code.language-mermaid"));
    if (!blocks.length) return;
    let i = 0;
    for (const code of blocks) {
      const pre = code.parentElement;
      const id = "mermaid-" + Date.now() + "-" + i++; // unique per render
      try {
        const { svg } = await mermaid.render(id, code.textContent);
        const wrap = document.createElement("div");
        wrap.className = "mermaid";
        wrap.innerHTML = svg;
        pre.replaceWith(wrap);
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
      renderMermaid(content);

      if (payload.resetScroll) window.scrollTo(0, 0);
    },

    // Used by the Windows host (macOS uses WKWebView.pageZoom instead).
    setZoom(factor) {
      document.documentElement.style.zoom = String(factor);
    },
  };

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
