// Web/json-tree.js
//
// Shared, offline JSON tree renderer for the preview page.
// Loaded as a plain script (no imports, no network) AFTER
// json-preview.js and BEFORE preview.js in index.html. It exposes:
//
//   globalThis.MDPJSONTree.mount(host, node, options) -> controller
//
//   `host`    a DOM element that receives the tree.
//   `node`    a parsed JSON node from MDPJSON.parse (the lossless node contract:
//             basic value { type, raw }, { type:"object", entries:[{key,rawKey,
//             value}] }, { type:"array", items:[...] }).
//   `options` may carry:
//     { documentID }  stable per-window identity used to key fold overrides.
//     { source }      the original source string, shown by the "Show raw source"
//                    option (the full, untruncated document).
//
// The returned controller for THIS mount (a LIVE tree controller):
//   {
//     complete: true,            // a valid node was mounted and self-manages
//     reason: null,
//     rendered,                  // number of rows built so far
//     host, node,
//     capped,                    // true once the global DOM cap is reached
//     destroy(),                 // tear this tree down, cancelling pending work
//     expandAll(), collapseAll(), showRaw()
//   }
//   { complete: false, reason: "not-a-node" }  host/node missing or malformed.
//
// Safety / losslessness (unchanged from phase 1): every value and every object
// key is rendered with its ORIGINAL token (raw / rawKey) as a TEXT NODE
// (createTextNode) — never innerHTML — so markup inside a string or key can
// neither be executed nor interpreted as HTML. Object key order and duplicate
// keys are preserved; empty containers show {} / []; numbers keep their exact
// source token. The tree never reaches marked, innerHTML, or the Markdown URL
// pipeline.
//
// Phase-2 behaviour:
//   * A small toolbar (Expand all / Collapse all / Show raw source) sits above
//     the tree.
//   * Each container is an actionable button carrying its type, child count and
//     (for entries) its key, with aria-expanded and an aria-label.
//   * Collapsed containers preview their first few keys/values (with a "… N
//     more" remainder) so the reader sees what is inside without expanding.
//   * Default fold: containers at depth 0..2 open, depth 3+ closed.
//   * Children are created ON DEMAND in requestAnimationFrame batches.
//   * Keyboard: when the tree holds focus, Up/Down move between visible rows
//     (containers and focusable leaves incl. empty containers), Right expands
//     and Left collapses the focused container.
//   * Fold overrides are stored in memory, keyed by documentID and an
//     unambiguous tree path. State is never reused across identities.
//
// Phase-3 additions:
//   * P5 — Path hints: every container and leaf row carries a native `title`
//     tooltip showing its JSON path (e.g. $.users[0].name). Deep containers
//     (depth >= DEEP_BADGE_DEPTH) show a small depth badge.
//   * P6 — Large-data enhancements:
//     - Initial per-container cap is computed from viewport height instead of a
//       fixed constant.
//     - IntersectionObserver replaces the "Show more" button: when a sentinel
//       near the bottom of a container scrolls into view, the next batch of
//       children loads automatically. A "Show more" button is used as a
//       fallback when IntersectionObserver is unavailable.
//     - Collapsing a container HIDES its children (hidden attribute) instead of
//       removing them from the DOM, so re-expanding is instant. A total DOM-row
//       cap (MAX_TOTAL_ROWS) prevents unbounded memory growth; the deepest hidden
//       containers are garbage-collected first.

(function (root) {
  "use strict";

  // ---- Tunables ---------------------------------------------------------
  var AUTO_OPEN_DEPTH = 2;        // containers at depth 0..2 open; depth >=3 closed
  var CHILDREN_BATCH = 48;        // child rows built per animation frame
  var MAX_CONTAINER_CAP = 500;    // hard upper bound on a single container's cap
  var ROW_HEIGHT_ESTIMATE = 22;   // px, typical for 13px monospace w/ line-height 1.4
  var DEFAULT_MAX_ROWS = 1200;    // global cap on simultaneously-visible rows
  var MAX_TOTAL_ROWS = 5000;      // total DOM rows (visible + hidden) before GC
  var DEEP_BADGE_DEPTH = 4;       // show a depth badge at nesting >= this
  var MAX_OVERRIDES = 4096;       // fold-override cap per document identity
  var PREVIEW_COUNT = 3;          // keys/items previewed inside a collapsed container
  var PREVIEW_VALUE_LEN = 20;     // max chars of a leaf value in a collapsed preview
  var PATH_SEP = "\u001f";        // JSON.stringify escapes control characters in keys.
  var IO_ROOT_MARGIN = "200px";   // load next batch 200px before sentinel enters view

  // Detect IntersectionObserver support once at module load.
  var HAS_IO = (typeof IntersectionObserver !== "undefined");

  // In-memory fold overrides, keyed by documentID -> { overrides: Map, ... }.
  // Never written to disk. A new identity (file or paste) gets its own map, so
  // state is never reused across identities or windows.
  var store = new Map();
  var MAX_STORE_SIZE = 32;

  // The single live tree the keyboard handler and the native bridge act on.
  var moduleActive = null;
  var keydownBound = false;

  // Shared IntersectionObserver for all tree sentinels.
  var sharedObserver = null;

  // ---- Scheduling (read rAF dynamically so a test override applies) ------
  function scheduleFrame(cb) {
    var fn = (typeof window !== "undefined" && window.requestAnimationFrame)
      || (typeof requestAnimationFrame !== "undefined" ? requestAnimationFrame : null);
    if (fn) return fn(cb);
    return setTimeout(function () { cb(0); }, 0);
  }
  function cancelScheduled(id) {
    var fn = (typeof window !== "undefined" && window.cancelAnimationFrame)
      || (typeof cancelAnimationFrame !== "undefined" ? cancelAnimationFrame : null);
    if (fn) fn(id); else clearTimeout(id);
  }

  // ---- Observer helpers (P6) -------------------------------------------
  function getObserver() {
    if (!HAS_IO) return null;
    if (sharedObserver) return sharedObserver;
    sharedObserver = new IntersectionObserver(function (entries) {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].isIntersecting) {
          var ctrl = entries[i].target._ctrl;
          if (ctrl) loadMore(ctrl);
        }
      }
    }, { rootMargin: IO_ROOT_MARGIN });
    return sharedObserver;
  }

  function observeSentinel(sentinel) {
    var obs = getObserver();
    if (obs && sentinel) obs.observe(sentinel);
  }
  function unobserveSentinel(sentinel) {
    var obs = getObserver();
    if (obs && sentinel) obs.unobserve(sentinel);
  }

  // ---- Path / occurrence helpers ----------------------------------------
  // An object child path segment encodes the DECODED key (JSON-quoted, so it is
  // unambiguous even for keys containing separators) and its occurrence index
  // within the parent object. An array child encodes its index. The container's
  // own type is checked when matching a stored override.
  function objectSegment(key, occ) {
    return "o:" + JSON.stringify(key) + ":" + occ;
  }
  function arraySegment(index) {
    return "a:" + index;
  }
  function joinPath(parentKey, segment) {
    return parentKey === "" ? segment : parentKey + PATH_SEP + segment;
  }
  function isDescendant(pathKey, parentKey) {
    if (parentKey === "") return true;
    var prefix = parentKey + PATH_SEP;
    return pathKey === parentKey ||
      (pathKey.length > parentKey.length && pathKey.slice(0, prefix.length) === prefix);
  }

  // P5: convert an internal pathKey to a human-readable JSON path like
  // $.users[0].profile.  Uses JSON.parse for the key segment (the segment
  // encodes a JSON-quoted string).  Falls back to a raw slice on parse error.
  function pathToHuman(pathKey) {
    if (!pathKey) return "$";
    var parts = pathKey.split(PATH_SEP);
    var result = "$";
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (p.charCodeAt(0) === 111) { // 'o'
        var colonIdx = p.lastIndexOf(":");
        var jsonStr = p.slice(2, colonIdx);
        var key;
        try { key = JSON.parse(jsonStr); } catch (e) { key = p.slice(2, colonIdx); }
        if (/^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(String(key))) {
          result += "." + key;
        } else {
          result += "[" + JSON.stringify(String(key)) + "]";
        }
      } else {
        // 'a:N'
        result += "[" + p.slice(2) + "]";
      }
    }
    return result;
  }

  // P6: compute the initial per-container cap from viewport height.
  function computeInitialCap() {
    var vh = (typeof window !== "undefined" && window.innerHeight)
      ? window.innerHeight : 800;
    var cap = Math.ceil(vh / ROW_HEIGHT_ESTIMATE);
    return Math.max(10, Math.min(cap, MAX_CONTAINER_CAP));
  }

  // P6: append a child row before the sentinel (if present) so the sentinel
  // stays at the bottom of the children container.
  function appendChildRow(c, row) {
    if (c.sentinelEl && c.sentinelEl.parentNode === c.childrenEl) {
      c.childrenEl.insertBefore(row, c.sentinelEl);
    } else {
      c.childrenEl.appendChild(row);
    }
  }

  // P6: garbage-collect the deepest hidden containers when total DOM rows
  // exceed MAX_TOTAL_ROWS.  Called after collapse / expand / bulk operations.
  function gcHiddenContainers(tree) {
    var allRows = tree.host.querySelectorAll('.json-row').length;
    if (allRows <= MAX_TOTAL_ROWS) return;
    var overBy = allRows - MAX_TOTAL_ROWS;
    // Collect hidden containers, deepest first.
    var hidden = [];
    for (var i = 0; i < tree.controllers.length; i++) {
      var c = tree.controllers[i];
      if (!c.expanded && c.childrenEl && c.childrenEl.hidden) {
        hidden.push(c);
      }
    }
    hidden.sort(function (a, b) { return b.depth - a.depth; });
    for (var j = 0; j < hidden.length && overBy > 0; j++) {
      var c2 = hidden[j];
      var rows = c2.childrenEl.querySelectorAll('.json-row').length;
      // Unobserve and remove the sentinel.
      if (c2.sentinelEl) {
        unobserveSentinel(c2.sentinelEl);
        c2.sentinelEl = null;
      }
      if (c2.showMoreEl) c2.showMoreEl = null;
      if (c2.childrenEl && c2.childrenEl.parentNode) {
        c2.rowEl.removeChild(c2.childrenEl);
      }
      c2.childrenEl = null;
      c2.built = 0;
      c2.cap = computeInitialCap();
      c2.occCounts = null;
      c2.renderedRows = 0;
      // Drop descendant controllers (their DOM is gone).
      tree.controllers = tree.controllers.filter(function (child) {
        return child === c2 || !isDescendant(child.pathKey, c2.pathKey);
      });
      overBy -= rows;
    }
  }

  // ---- Fold-override store (per document identity) ----------------------
  function docState(documentID) {
    if (documentID == null) {
      return { overrides: Object.create(null), order: [] };
    }

    var s = store.get(documentID);
    if (s) {
      // Refresh LRU
      store.delete(documentID);
      store.set(documentID, s);
      return s;
    }

    s = { overrides: Object.create(null), order: [] };
    store.set(documentID, s);

    if (store.size > MAX_STORE_SIZE) {
      var firstKey = store.keys().next().value;
      store.delete(firstKey);
    }

    return s;
  }

  // Prune overrides that no longer apply to `node`: any stored path that is
  // missing, or whose container type changed, is discarded even when it was
  // hidden. Done by a single bounded walk of the parsed tree (the parser already
  // caps node count), so a huge document does not blow up this pass.
  function pruneAgainst(node, state) {
    if (state.order.length === 0) return;
    var valid = Object.create(null); // pathKey -> type
    collectTypes(node, "", valid);
    var next = Object.create(null);
    var nextOrder = [];
    for (var i = 0; i < state.order.length; i++) {
      var key = state.order[i];
      var rec = state.overrides[key];
      if (!rec) continue;
      var type = valid[key];
      if (type && type === rec.type) {
        next[key] = rec;
        nextOrder.push(key);
      }
      // else: removed path or type change -> discarded.
    }
    state.overrides = next;
    state.order = nextOrder;
  }

  // One walk that records, for every container, its current type keyed by its
  // path. Bounded by the parser's node cap (the tree already exists). `pathKey`
  // is the parent's path ("" for the root).
  function collectTypes(node, pathKey, out) {
    if (!node || (node.type !== "object" && node.type !== "array")) return;
    out[pathKey] = node.type;
    if (node.type === "object") {
      var occ = Object.create(null);
      var entries = node.entries || [];
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var k = e.key;
        var o = occ[k] || 0;
        occ[k] = o + 1;
        var childKey = joinPath(pathKey, objectSegment(k, o));
        var child = e.value;
        if (child && (child.type === "object" || child.type === "array")) {
          collectTypes(child, childKey, out);
        }
      }
    } else {
      var items = node.items || [];
      for (var j = 0; j < items.length; j++) {
        var it = items[j];
        var childKey2 = joinPath(pathKey, arraySegment(j));
        if (it && (it.type === "object" || it.type === "array")) {
          collectTypes(it, childKey2, out);
        }
      }
    }
  }

  // ---- DOM helpers ------------------------------------------------------
  function textNode(doc, s) { return doc.createTextNode(s); }

  function setAttribute(el, name, value) {
    if (el.setAttribute) el.setAttribute(name, String(value));
  }
  function classAdd(el, c) {
    if (el.classList && el.classList.add) el.classList.add(c);
  }

  function makeEl(doc, tag, className) {
    var el = doc.createElement(tag);
    el.className = className;
    return el;
  }

  // A focusable leaf: a primitive value or an empty container. Keyboard-
  // focusable (tabindex) so Up/Down can land on it.
  function appendLeafValue(parent, doc, node) {
    var el = makeEl(doc, "span", "json-value json-" + node.type);
    if (node.type === "object" || node.type === "array") {
      appendText(el, doc, node.type === "object" ? "{}" : "[]");
      parent.appendChild(el);
      return el;
    }
    appendText(el, doc, node.raw);
    parent.appendChild(el);
    return el;
  }

  function appendText(parent, doc, text) {
    parent.appendChild(doc.createTextNode(text));
  }

  // A short, single-line preview of a value for a COLLAPSED container label.
  // Nested containers collapse to "{ … N keys }" / "[ … N items ]"; basic values
  // show their original token truncated to PREVIEW_VALUE_LEN. Everything is a
  // text node, so markup in a string or key stays inert. Empty containers show
  // just "{}" / "[]". Appends text directly to `parent`.
  function appendValuePreview(parent, doc, node, maxLen) {
    if (!node || node.type !== "object" && node.type !== "array") {
      var raw = node && node.raw != null ? String(node.raw) : "";
      if (raw.length > maxLen) raw = raw.slice(0, maxLen) + "\u2026";
      appendText(parent, doc, raw);
      return;
    }
    var count = node.type === "object" ? (node.entries ? node.entries.length : 0)
                                      : (node.items ? node.items.length : 0);
    var open = node.type === "object" ? "{" : "[";
    var close = node.type === "object" ? "}" : "]";
    appendText(parent, doc, open);
    if (count > 0) {
      var unit = node.type === "object"
        ? (count === 1 ? "key" : "keys") : (count === 1 ? "item" : "items");
      appendText(parent, doc, "\u2026 " + count + " " + unit);
    }
    appendText(parent, doc, close);
  }

  function pluralKeys(n) { return n === 1 ? "key" : "keys"; }
  function pluralItems(n) { return n === 1 ? "item" : "items"; }

  // ---- Tree instance ----------------------------------------------------
  function createTree(host, node, doc, options) {
    return {
      host: host,
      node: node,
      doc: doc,
      isJSON: true,
      alive: true,
      documentID: options.documentID != null ? options.documentID : null,
      source: options.source || "",
      maxRows: (options.maxRows && options.maxRows > 0) ? options.maxRows : DEFAULT_MAX_ROWS,
      rowsUsed: 0,
      capped: false,
      pending: [],          // containers that need children built (FIFO)
      controllers: [],      // all live container controllers
      frameId: null,
      expandAllMode: false,
      state: docState(options.documentID),
      limitEl: null,
      rootEl: null,
      toolbar: null
    };
  }

  function defaultExpanded(tree, c) {
    var rec = tree.state.overrides[c.pathKey];
    if (rec) return rec.exp === true;
    return c.depth <= AUTO_OPEN_DEPTH;
  }

  // Build a container's toggle row (and its children placeholder if expanded).
  function hasChildren(node) {
    return (node.type === "object" && node.entries.length > 0) ||
      (node.type === "array" && node.items.length > 0);
  }

  function makeContainerRow(tree, node, depth, pathKey, name) {
    var doc = tree.doc;
    var type = node.type; // "object" | "array"
    var childCount = type === "object" ? (node.entries ? node.entries.length : 0)
                                     : (node.items ? node.items.length : 0);
    var c = {
      tree: tree, node: node, type: type, depth: depth, pathKey: pathKey,
      name: name, childCount: childCount,
      built: 0, cap: computeInitialCap(), expanded: false,
      rowEl: null, toggleEl: null, childrenEl: null, showMoreEl: null,
      sentinelEl: null,
      occCounts: null, renderedRows: 0
    };
    var row = makeEl(doc, "div", "json-row json-container json-" + type);

    // P5: native tooltip with human-readable path + type + count.
    var unit = type === "object" ? pluralKeys(childCount) : pluralItems(childCount);
    var title = pathToHuman(pathKey) + " \u2014 " + type + ", " + childCount + " " + unit;
    setAttribute(row, "title", title);

    var btn = makeEl(doc, "button", "json-toggle json-" + type);
    btn.type = "button";
    setAttribute(btn, "tabindex", "0");
    btn._ctrl = c;
    btn.addEventListener("click", function () { setExpanded(c, !c.expanded); });
    c.rowEl = row;
    c.toggleEl = btn;

    // Expand decision: an explicit override wins, else the depth default. While
    // an expandAll is in progress, open everything (bounded by the global cap).
    var expanded = tree.expandAllMode ? true : defaultExpanded(tree, c);
    c.expanded = expanded;
    if (tree.expandAllMode) recordOverride(tree, c, true);
    setExpandedAttr(c, expanded);
    renderCollapsedLabel(c);

    row.appendChild(btn);

    // P5: depth badge for deep containers.
    if (depth >= DEEP_BADGE_DEPTH) {
      var badge = makeEl(doc, "span", "json-depth-badge");
      appendText(badge, doc, String(depth));
      row.appendChild(badge);
    }

    tree.controllers.push(c);
    tree.rowsUsed++;

    if (expanded) {
      c.childrenEl = makeEl(doc, "div", "json-children");
      row.appendChild(c.childrenEl);
      c.cap = tree.expandAllMode ? c.childCount : computeInitialCap();

      // P6: add sentinel if there's more to load beyond the initial cap.
      if (c.childCount > c.cap) {
        c.sentinelEl = makeEl(doc, "div", "json-sentinel");
        c.sentinelEl._ctrl = c;
        c.childrenEl.appendChild(c.sentinelEl);
        observeSentinel(c.sentinelEl);
      }

      queueContainer(tree, c);
    }
    // A collapsed empty container already shows "{}" / "[]" via
    // renderCollapsedLabel, so no extra closing bracket is needed here.
    return c;
  }

  function setExpandedAttr(c, expanded) {
    setAttribute(c.toggleEl, "aria-expanded", expanded ? "true" : "false");
    c.toggleEl.className = "json-toggle json-" + c.type + (expanded ? "" : " json-collapsed");
  }

  // The button's visible label. Collapsed: the opening bracket, a short preview
  // of the first PREVIEW_COUNT keys/items (with a "… N more" remainder when
  // there are more), then the closing bracket. Expanded: just the opening
  // bracket (children render below). The accessible name always reports the
  // full count, independent of the preview.
  function renderCollapsedLabel(c) {
    var btn = c.toggleEl;
    while (btn.firstChild) btn.removeChild(btn.firstChild);
    var doc = c.tree.doc;
    var openPunct = c.type === "object" ? "{" : "[";
    var closePunct = c.type === "object" ? "}" : "]";
    appendText(btn, doc, openPunct);
    if (!c.expanded && c.childCount > 0) {
      var shown, total, i;
      if (c.type === "object") {
        var entries = c.node.entries || [];
        total = entries.length;
        shown = Math.min(total, PREVIEW_COUNT);
        for (i = 0; i < shown; i++) {
          var e = entries[i];
          var keySpan = makeEl(doc, "span", "json-key");
          appendText(keySpan, doc, e.rawKey);
          btn.appendChild(keySpan);
          appendText(btn, doc, ": ");
          appendValuePreview(btn, doc, e.value, PREVIEW_VALUE_LEN);
          if (i + 1 < shown) appendText(btn, doc, ", ");
        }
        if (total > shown) {
          var moreObj = makeEl(doc, "span", "json-count json-more");
          appendText(moreObj, doc, ", \u2026 " + (total - shown) + " more " + pluralKeys(total - shown));
          btn.appendChild(moreObj);
        }
      } else {
        var items = c.node.items || [];
        total = items.length;
        shown = Math.min(total, PREVIEW_COUNT);
        for (i = 0; i < shown; i++) {
          appendValuePreview(btn, doc, items[i], PREVIEW_VALUE_LEN);
          if (i + 1 < shown) appendText(btn, doc, ", ");
        }
        if (total > shown) {
          var moreArr = makeEl(doc, "span", "json-count json-more");
          appendText(moreArr, doc, ", \u2026 " + (total - shown) + " more " + pluralItems(total - shown));
          btn.appendChild(moreArr);
        }
      }
    }
    appendText(btn, doc, closePunct);
    // Accessible name: type + count + key/position, independent of fold state.
    var name = c.type === "object" ? "Object" : "Array";
    name += ", " + c.childCount + (c.type === "object" ? (c.childCount === 1 ? " key" : " keys")
                                                       : (c.childCount === 1 ? " item" : " items"));
    if (c.name != null) name += " " + c.name;
    setAttribute(btn, "aria-label", name);
  }

  // Build up to `budget` child rows of container `c`. Returns rows made.
  function buildChildren(tree, c, budget) {
    var doc = tree.doc;
    var made = 0;
    if (c.type === "object") {
      var entries = c.node.entries || [];
      var n = entries.length;
      var occ = c.occCounts || (c.occCounts = Object.create(null));
      for (var i = c.built; i < n && made < budget; i++) {
        if (tree.rowsUsed >= tree.maxRows) { tree.capped = true; break; }
        var e = entries[i];
        var key = e.key;
        var o = occ[key] || 0;
        occ[key] = o + 1;
        var seg = objectSegment(key, o);
        var childPath = joinPath(c.pathKey, seg);
        var row = makeEl(doc, "div", "json-row json-leaf json-entry");

        // P5: title on leaf rows.
        var leafNode = e.value;
        var leafTitle = pathToHuman(childPath);
        if (leafNode.type !== "object" && leafNode.type !== "array") {
          leafTitle += " : " + leafNode.type;
        }
        setAttribute(row, "title", leafTitle);

        var keySpan = makeEl(doc, "span", "json-key");
        appendText(keySpan, doc, e.rawKey);
        row.appendChild(keySpan);
        appendText(row, doc, ": ");
        var child = e.value;
        if (hasChildren(child)) {
          var cc = makeContainerRow(tree, child, c.depth + 1, childPath, key);
          row.appendChild(cc.rowEl);
        } else {
          row.tabindex = "0";
          setAttribute(row, "tabindex", "0");
          appendLeafValue(row, doc, child);
        }
        if (i + 1 < n) appendText(row, doc, ",");
        appendChildRow(c, row);
        tree.rowsUsed++;
        c.renderedRows++;
        c.built++;
        made++;
      }
    } else {
      var items = c.node.items || [];
      var m = items.length;
      for (var j = c.built; j < m && made < budget; j++) {
        if (tree.rowsUsed >= tree.maxRows) { tree.capped = true; break; }
        var child2 = items[j];
        var aSeg = arraySegment(j);
        var aPath = joinPath(c.pathKey, aSeg);
        var row2 = makeEl(doc, "div", "json-row json-leaf json-item");

        // P5: title on array item rows.
        var itemTitle = pathToHuman(aPath);
        if (child2.type !== "object" && child2.type !== "array") {
          itemTitle += " : " + child2.type;
        }
        setAttribute(row2, "title", itemTitle);

        if (hasChildren(child2)) {
          var cc2 = makeContainerRow(tree, child2, c.depth + 1, aPath, "index " + j);
          row2.appendChild(cc2.rowEl);
        } else {
          setAttribute(row2, "tabindex", "0");
          appendLeafValue(row2, doc, child2);
        }
        if (j + 1 < m) appendText(row2, doc, ",");
        appendChildRow(c, row2);
        tree.rowsUsed++;
        c.renderedRows++;
        c.built++;
        made++;
      }
    }
    if (c.built >= c.childCount) {
      var closePunct = c.type === "object" ? "}" : "]";
      appendText(c.childrenEl, doc, closePunct);
    }
    return made;
  }

  // P6: Show / update / remove the sentinel (auto-load) and/or "Show more"
  // (fallback when IO is unavailable) for a container with remaining children.
  function finalizeContainer(tree, c) {
    var hasMore = c.built < c.childCount;
    if (hasMore && !tree.capped) {
      // Ensure sentinel exists for auto-loading.
      if (!c.sentinelEl) {
        c.sentinelEl = makeEl(tree.doc, "div", "json-sentinel");
        c.sentinelEl._ctrl = c;
        c.childrenEl.appendChild(c.sentinelEl);
        observeSentinel(c.sentinelEl);
      }
      // Fallback "Show more" button when IntersectionObserver is unavailable.
      if (!HAS_IO) {
        if (!c.showMoreEl) {
          var b = makeEl(tree.doc, "button", "json-show-more");
          b.type = "button";
          setAttribute(b, "tabindex", "0");
          b._ctrl = c;
          b.addEventListener("click", function () { loadMore(c); });
          c.childrenEl.appendChild(b);
          c.showMoreEl = b;
        }
        var remaining = c.childCount - c.built;
        c.showMoreEl.textContent = "Show more (" + remaining + " more)";
      } else if (c.showMoreEl) {
        // IO available: remove any leftover "Show more" button.
        if (c.showMoreEl.parentNode) c.showMoreEl.parentNode.removeChild(c.showMoreEl);
        c.showMoreEl = null;
      }
    } else {
      // Fully loaded or globally capped: clean up sentinel / "Show more".
      if (c.sentinelEl) {
        unobserveSentinel(c.sentinelEl);
        if (c.sentinelEl.parentNode) c.sentinelEl.parentNode.removeChild(c.sentinelEl);
        c.sentinelEl = null;
      }
      if (c.showMoreEl) {
        if (c.showMoreEl.parentNode) c.showMoreEl.parentNode.removeChild(c.showMoreEl);
        c.showMoreEl = null;
      }
    }
  }

  function loadMore(c) {
    var tree = c.tree;
    if (!tree.alive || tree.capped) return;
    c.cap = Math.min(c.childCount, c.cap + computeInitialCap());
    queueContainer(tree, c);
  }

  function queueContainer(tree, c) {
    if (!tree.alive) return;
    if (c.built >= c.childCount || c.built >= c.cap) return;
    for (var i = 0; i < tree.pending.length; i++) {
      if (tree.pending[i] === c) return;
    }
    tree.pending.push(c);
    if (tree.frameId == null) tree.frameId = scheduleFrame(function () { runFrame(tree); });
  }

  // One animation-frame batch: build a bounded number of rows across all pending
  // containers. Cancels on disposal/collapse via tree.alive and the skip test.
  function runFrame(tree) {
    tree.frameId = null;
    if (!tree.alive) return;
    var prevCapped = tree.capped;
    var budget = CHILDREN_BATCH;
    var i = 0;
    while (i < tree.pending.length && budget > 0 && tree.alive) {
      var c = tree.pending[i];
      // Skip containers that were collapsed or destroyed (row removed from DOM).
      // P6: also skip hidden containers (collapsed but children preserved).
      if (!c.expanded || !c.childrenEl || !c.childrenEl.parentNode || c.childrenEl.hidden) {
        tree.pending.splice(i, 1);
        continue;
      }
      var made = buildChildren(tree, c, budget);
      if (made > 0) budget -= made;
      if (c.built >= c.childCount || tree.capped || c.built >= c.cap) {
        finalizeContainer(tree, c);
        if (tree.capped) showLimitStatus(tree);
        tree.pending.splice(i, 1);
      } else {
        i++;
      }
    }
    if (tree.expandAllMode) {
      // An expandAll opens every reachable container; stop once nothing remains
      // to build or the global cap is hit (the limit status is already shown).
      if (tree.pending.length === 0 || tree.capped) tree.expandAllMode = false;
    }
    if (tree.alive && tree.pending.length) {
      tree.frameId = scheduleFrame(function () { runFrame(tree); });
    } else if (tree.capped && !prevCapped) {
      showLimitStatus(tree);
    }
    // Keep the visible-row count authoritative after each batch so the cap and
    // the "limit" status reflect the real on-screen state (not the within-frame
    // running estimate, which can over-count nested hidden containers).
    if (tree.alive) recomputeRowsUsed(tree);
    if (typeof tree.onProgress === "function") tree.onProgress();
  }

  function showLimitStatus(tree) {
    if (tree.limitEl) return;
    var el = makeEl(tree.doc, "div", "json-limit");
    setAttribute(el, "role", "status");
    appendText(el, tree.doc,
      "Reached the size limit for this preview; use \u201CShow raw source\u201D for the full document.");
    tree.host.insertBefore(el, tree.host.firstChild);
    tree.limitEl = el;
  }

  // P6: authoritative visible-row count. A row counts toward the cap only when
  // it is actually visible, i.e. it has no hidden ancestor .json-children. This
  // is recomputed after any fold change so that nested hidden containers never
  // double-count toward the cap. It also reconciles the capped flag and the
  // "limit" status with the current visible state.
  function recomputeRowsUsed(tree) {
    var rows = tree.host.querySelectorAll(".json-row");
    var count = 0;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].closest("[hidden]")) continue;
      count++;
    }
    tree.rowsUsed = count;
    tree.capped = count >= tree.maxRows;
    if (tree.capped) {
      showLimitStatus(tree);
    } else if (tree.limitEl) {
      if (tree.limitEl.remove) tree.limitEl.remove();
      else if (tree.limitEl.parentNode) tree.limitEl.parentNode.removeChild(tree.limitEl);
      tree.limitEl = null;
    }
  }

  // Expand / collapse a single container, recording the manual override.
  function setExpanded(c, expanded) {
    var tree = c.tree;
    if (!tree.alive) return;
    c.expanded = expanded;
    setExpandedAttr(c, expanded);
    renderCollapsedLabel(c);
    if (expanded) {
      if (c.childrenEl && c.childrenEl.hidden) {
        // P6: unhide preserved children (instant re-expand).
        c.childrenEl.hidden = false;
        // Resume building if not yet complete.
        if (c.built < c.childCount && c.built < c.cap) {
          queueContainer(tree, c);
        }
      } else if (!c.childrenEl) {
        c.childrenEl = makeEl(tree.doc, "div", "json-children");
        c.rowEl.appendChild(c.childrenEl);
        c.built = 0;
        c.cap = computeInitialCap();
        c.showMoreEl = null;
        c.sentinelEl = null;
        if (c.childCount > c.cap) {
          c.sentinelEl = makeEl(tree.doc, "div", "json-sentinel");
          c.sentinelEl._ctrl = c;
          c.childrenEl.appendChild(c.sentinelEl);
          observeSentinel(c.sentinelEl);
        }
        queueContainer(tree, c);
      }
    } else {
      collapseContainer(c);
    }
    // Rows added/removed are counted authoritatively from the DOM so nested
    // hidden containers never double-count toward the cap.
    recomputeRowsUsed(tree);
    recordOverride(tree, c, expanded);
  }

  // P6: collapse HIDES children instead of removing them (fast re-expand).
  // The caller (setExpanded) reconciles rowsUsed via recomputeRowsUsed; this
  // only flips the hidden flag and prunes the pending queue.
  function collapseContainer(c) {
    var tree = c.tree;
    if (c.childrenEl && c.childrenEl.parentNode) {
      c.childrenEl.hidden = true;
    }
    // Preserve built/cap/occCounts for resume.

    // Drop this container and its descendants from the pending queue.
    for (var i = tree.pending.length - 1; i >= 0; i--) {
      var t = tree.pending[i];
      if (t === c || isDescendant(t.pathKey, c.pathKey)) tree.pending.splice(i, 1);
    }

    // P6: GC hidden containers if total DOM rows exceed the cap.
    gcHiddenContainers(tree);
  }

  // Record a manual fold as an override (bounded). If it matches the default we
  // clear any stored override so the map stays minimal and new paths stay
  // default.
  function recordOverride(tree, c, expanded) {
    var state = tree.state;
    var isDefault = c.depth <= AUTO_OPEN_DEPTH;
    var sameAsDefault = (expanded === isDefault);
    var exists = state.overrides[c.pathKey];
    if (sameAsDefault) {
      if (exists) {
        delete state.overrides[c.pathKey];
        var orderIdx = state.order.indexOf(c.pathKey);
        if (orderIdx !== -1) state.order.splice(orderIdx, 1);
      }
      return;
    }
    if (!exists && (state.order.length >= MAX_OVERRIDES)) return; // bounded
    if (!exists) state.order.push(c.pathKey);
    state.overrides[c.pathKey] = { exp: expanded, type: c.type };
  }

  // ---- Bulk operations --------------------------------------------------
  function expandAll(tree) {
    if (!tree.alive || tree.rawMode) return;
    tree.capped = false;
    tree.expandAllMode = true;
    // Open every currently-known container; newly-built ones open in turn.
    for (var i = 0; i < tree.controllers.length; i++) {
      var c = tree.controllers[i];
      if (!c.expanded) {
        c.expanded = true;
        setExpandedAttr(c, true);
        renderCollapsedLabel(c);
      }
      c.cap = c.childCount;
      recordOverride(tree, c, true);
      if (c.childrenEl && c.childrenEl.hidden) {
        // P6: unhide preserved children (instant re-expand). Rows are counted
        // authoritatively by recomputeRowsUsed after the build, so we do not
        // add here (that would double-count nested rows).
        c.childrenEl.hidden = false;
      } else if (!c.childrenEl) {
        c.childrenEl = makeEl(tree.doc, "div", "json-children");
        c.rowEl.appendChild(c.childrenEl);
      }
      // Remove "Show more" / sentinel for expand-all (we're building everything).
      if (c.showMoreEl) {
        if (c.showMoreEl.parentNode) c.showMoreEl.parentNode.removeChild(c.showMoreEl);
        c.showMoreEl = null;
      }
      if (c.sentinelEl) {
        unobserveSentinel(c.sentinelEl);
        if (c.sentinelEl.parentNode) c.sentinelEl.parentNode.removeChild(c.sentinelEl);
        c.sentinelEl = null;
      }
      if (c.built < c.childCount) queueContainer(tree, c);
    }
    if (tree.controllers.length === 0 || tree.pending.length === 0) {
      tree.expandAllMode = false;
    }
  }

  function collapseAll(tree) {
    if (!tree.alive || tree.rawMode) return;
    cancelPending(tree);
    tree.expandAllMode = false;
    var root = tree.controllers.find(function (container) {
      return container.pathKey === "";
    });
    if (!root) return;
    var focusWasInside = tree.rootEl && tree.rootEl.contains(tree.doc.activeElement);
    // Collapse EVERY container: mark each collapsed and hide its childrenEl so the
    // preserved-DOM invariant holds uniformly (each container is independently
    // collapsible, not merely nested inside a hidden ancestor). rowsUsed is
    // reconciled by recomputeRowsUsed afterwards.
    for (var i = 0; i < tree.controllers.length; i++) {
      var c = tree.controllers[i];
      c.expanded = false;
      setExpandedAttr(c, false);
      renderCollapsedLabel(c);
      if (c.childrenEl) c.childrenEl.hidden = true;
      // Clear any sentinel / "Show more" affordances that are no longer needed.
      if (c.sentinelEl) {
        unobserveSentinel(c.sentinelEl);
        if (c.sentinelEl.parentNode) c.sentinelEl.parentNode.removeChild(c.sentinelEl);
        c.sentinelEl = null;
      }
      if (c.showMoreEl) {
        if (c.showMoreEl.parentNode) c.showMoreEl.parentNode.removeChild(c.showMoreEl);
        c.showMoreEl = null;
      }
      recordOverride(tree, c, false);
    }
    if (focusWasInside) root.toggleEl.focus();
    recomputeRowsUsed(tree);
    // P6: GC hidden containers after bulk collapse.
    gcHiddenContainers(tree);
  }

  function cancelPending(tree) {
    if (tree.frameId != null) { cancelScheduled(tree.frameId); tree.frameId = null; }
    tree.pending.length = 0;
  }

  // ---- Raw-source option -----------------------------------------------
  function showRaw(tree) {
    if (!tree.alive) return;
    cancelPending(tree);
    // P6: unobserve all sentinels before clearing controllers.
    for (var s = 0; s < tree.controllers.length; s++) {
      var sc = tree.controllers[s];
      if (sc.sentinelEl) {
        unobserveSentinel(sc.sentinelEl);
        sc.sentinelEl = null;
      }
    }
    tree.rawMode = true;
    tree.controllers.length = 0;
    tree.rowsUsed = 0;
    tree.capped = false;
    tree.limitEl = null;
    tree.pending.length = 0;
    if (tree.host) {
      tree.host.textContent = '';
    }
    var pre = makeEl(tree.doc, "pre", "json-preview json-source");
    appendText(pre, tree.doc, tree.source);
    tree.host.appendChild(pre);
    // A one-way toggle back to the tree, reusing the saved fold overrides.
    var back = makeEl(tree.doc, "button", "json-toolbar-btn json-show-tree");
    back.type = "button";
    back.textContent = "Show tree";
    back.addEventListener("click", function () {
      tree.rawMode = false;
      if (tree.host) {
        tree.host.textContent = '';
      }
      buildRoot(tree);
    });
    tree.host.appendChild(back);
  }

  // ---- Keyboard ---------------------------------------------------------
  // A single document-level handler delegates to the live JSON tree. It only
  // acts for plain arrow keys with no modifier (so ⌘A / Ctrl combos and input
  // fields keep native behaviour) and only when focus is inside this tree.
  function onKeyDown(e) {
    var tree = moduleActive;
    if (!tree || !tree.alive || tree.rawMode) return;
    if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return; // never swallow ⌘/Ctrl/Option/Shift
    var key = e.key;
    if (key !== "ArrowUp" && key !== "ArrowDown" && key !== "ArrowLeft" && key !== "ArrowRight") return;
    var doc = tree.doc;
    var active = doc.activeElement;
    if (!active || !tree.host.contains(active)) return;
    if (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable) return;
    var sel = (typeof window !== "undefined" && window.getSelection) ? window.getSelection() : null;
    if (sel && sel.type && sel.type !== "None" && sel.type !== "Caret") return;
    var rows = visibleRows(tree);
    var idx = -1;
    for (var i = 0; i < rows.length; i++) { if (rows[i] === active) { idx = i; break; } }
    if (idx < 0) {
      if (rows.length) { rows[0].focus(); e.preventDefault(); }
      return;
    }

    e.preventDefault();
    if (key === "ArrowDown") {
      var next = rows[idx + 1];
      if (next) next.focus();
    } else if (key === "ArrowUp") {
      var prev = rows[idx - 1];
      if (prev) prev.focus();
    } else if (key === "ArrowRight") {
      var c = toggleFor(active, tree);
      if (c && !c.expanded) setExpanded(c, true);
    } else if (key === "ArrowLeft") {
      var c2 = toggleFor(active, tree);
      if (c2 && c2.expanded) setExpanded(c2, false);
    }
  }

  function toggleFor(el, tree) {
    // The focused element is either a toggle button or a leaf row that holds a
    // nested container row; return the relevant container controller if any.
    if (el._ctrl) return el._ctrl;
    var nested = el.querySelector ? el.querySelector(".json-toggle") : null;
    return nested ? nested._ctrl : null;
  }

  function visibleRows(tree) {
    var els = tree.host.querySelectorAll('.json-toggle[tabindex="0"], .json-leaf[tabindex="0"]');
    var out = [];
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.closest('[hidden]')) continue;
      out.push(el);
    }
    return out;
  }

  function ensureKeydown(doc) {
    if (keydownBound) return;
    keydownBound = true;
    doc.addEventListener("keydown", onKeyDown);
  }

  // ---- Mount / destroy --------------------------------------------------
  function buildRoot(tree) {
    var doc = tree.doc;
    var rootRow = makeEl(doc, "div", "json-tree json-root");
    // Toolbar (always present; the "Show raw source" button is the explicit raw
    // option and also satisfies the "continuation/limit" affordance check).
    var toolbar = makeEl(doc, "div", "json-toolbar");
    var expand = makeEl(doc, "button", "json-toolbar-btn");
    expand.type = "button";
    expand.textContent = "Expand all";
    expand.addEventListener("click", function () { expandAll(tree); });
    var collapse = makeEl(doc, "button", "json-toolbar-btn");
    collapse.type = "button";
    collapse.textContent = "Collapse all";
    collapse.addEventListener("click", function () { collapseAll(tree); });
    var raw = makeEl(doc, "button", "json-toolbar-btn");
    raw.type = "button";
    raw.textContent = "Show raw source";
    raw.addEventListener("click", function () { showRaw(tree); });
    toolbar.appendChild(expand);
    toolbar.appendChild(collapse);
    toolbar.appendChild(raw);
    rootRow.appendChild(toolbar);
    tree.toolbar = toolbar;

    var rootNode = tree.node;
    if (hasChildren(rootNode)) {
      var rootC = makeContainerRow(tree, rootNode, 0, "", null);
      rootRow.appendChild(rootC.rowEl);
    } else {
      var leafRow = makeEl(doc, "div", "json-row json-leaf json-root-leaf");
      setAttribute(leafRow, "tabindex", "0");
      appendLeafValue(leafRow, doc, rootNode);
      rootRow.appendChild(leafRow);
      tree.rowsUsed++;
    }
    tree.host.appendChild(rootRow);
    tree.rootEl = rootRow;
  }

  function destroyTree(tree) {
    if (!tree.alive) return;
    cancelPending(tree);
    tree.alive = false;
    // P6: unobserve all sentinels.
    for (var i = 0; i < tree.controllers.length; i++) {
      var c = tree.controllers[i];
      if (c.sentinelEl) {
        unobserveSentinel(c.sentinelEl);
        c.sentinelEl = null;
      }
    }
    // Override store is keyed by document identity and persists across reloads,
    // so we deliberately do NOT clear it here.
    if (tree.rootEl && tree.rootEl.parentNode) tree.host.removeChild(tree.rootEl);
    tree.controllers.length = 0;
    tree.pending.length = 0;
  }

  function mount(host, node, options) {
    var doc = (typeof document !== "undefined") ? document : null;
    var controller = {
      complete: false, reason: null, rendered: 0, capped: false,
      host: host, node: node,
      destroy: function () {}, expandAll: function () {},
      collapseAll: function () {}, showRaw: function () {}
    };

    if (!host || !doc || node === null || typeof node !== "object" || typeof node.type !== "string") {
      controller.reason = "not-a-node";
      return controller;
    }

    options = options || {};
    // Tear down any previous tree on this host first.
    if (host._activeTree) destroyTree(host._activeTree);

    var tree = createTree(host, node, doc, options);
    host._activeTree = tree;
    moduleActive = tree;

    // Prune stale overrides (removed / type-changed paths) against this parse.
    pruneAgainst(node, tree.state);
    ensureKeydown(doc);
    buildRoot(tree);
    tree.rendered = tree.rowsUsed;

    controller.complete = true;
    controller.reason = null;
    controller.destroy = function () {
      destroyTree(tree);
      if (moduleActive === tree) moduleActive = null;
      if (host._activeTree === tree) host._activeTree = null;
    };
    controller.expandAll = function () { expandAll(tree); };
    controller.collapseAll = function () { collapseAll(tree); };
    controller.showRaw = function () { showRaw(tree); };
    if (options.onProgress) tree.onProgress = options.onProgress;
    return controller;
  }

  var MDPJSONTree = {
    mount: mount,
    limits: {
      autoOpenDepth: AUTO_OPEN_DEPTH,
      childrenBatch: CHILDREN_BATCH,
      maxContainerCap: MAX_CONTAINER_CAP,
      maxRows: DEFAULT_MAX_ROWS,
      maxTotalRows: MAX_TOTAL_ROWS,
      deepBadgeDepth: DEEP_BADGE_DEPTH,
      maxOverrides: MAX_OVERRIDES,
      rowHeightEstimate: ROW_HEIGHT_ESTIMATE,
      hasIntersectionObserver: HAS_IO
    },
    // Used by the native menu bridge and the markdown branch.
    clearActive: function () {
      if (moduleActive) { destroyTree(moduleActive); moduleActive = null; }
    },
    expandAll: function () { if (moduleActive && moduleActive.alive) expandAll(moduleActive); },
    collapseAll: function () { if (moduleActive && moduleActive.alive) collapseAll(moduleActive); },
    showRawSource: function () { if (moduleActive && moduleActive.alive) showRaw(moduleActive); }
  };

  if (root && typeof root === "object") root.MDPJSONTree = MDPJSONTree;
  if (typeof module !== "undefined" && module.exports) module.exports = MDPJSONTree;
})(typeof globalThis !== "undefined" ? globalThis : this);
