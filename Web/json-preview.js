// Web/json-preview.js
//
// Shared, offline JSON parser for the preview page. It is loaded as a plain
// script (no imports, no network) and exposes:
//
//   globalThis.MDPJSON.parse(source) ->
//     { ok: true,  node }                            on success
//     { ok: false, error: { kind, message, offset? } }  on failure
//
//   `kind` is "syntax" or "limit". `offset`, when present, is a UTF-16 index
//   into `source` at a position that is certain. It is omitted when the
//   location cannot be stated reliably (notably for "limit" errors, which are
//   resource bounds rather than a position in the input).
//
// Node shapes produced by this version (step 11: full JSON):
//   { type: "string",  raw: <raw quoted token>, value: <decoded string> }
//   { type: "number",  raw: <exact source token> }   // NOT a JS number
//   { type: "boolean", raw: "true" | "false" }
//   { type: "null",    raw: "null" }
//   { type: "object",  entries: [ { key, rawKey, value: Node }, ... ] }
//   { type: "array",   items: [ Node, ... ] }
//
// Objects preserve key order and duplicate keys (no de-duplication, no
// merging). Arrays preserve item order.
//
// Precision: a number node keeps the exact source token and is never converted
// with Number()/JSON.parse, so large integers and high-precision decimals
// survive without floating-point round-tripping. String tokens (values and
// object keys) are validated by parsing the *bounded* token with JSON.parse
// (explicitly allowed for a single already-bounded string token); the whole
// source and numbers are never handed to JSON.parse.
//
// Limits (initial safety bounds, tunable from measurement):
//   - Container nesting depth is capped at 128; deeper nesting is a "limit"
//     error.
//   - The running total of value nodes plus object keys is capped at 250,000;
//     exceeding it is a "limit" error.
//
// A "limit" error is distinct from a "syntax" error so the display layer can
// present it differently. A limit error carries no offset.
//
// Step 12 wires this parser into the preview display.

(function (root) {
  "use strict";

  // Resource limits.
  var MAX_CONTAINER_DEPTH = 128;      // deepest allowed nesting of containers
  var MAX_NODES_AND_KEYS = 250000;    // value nodes + object keys, combined

  // Standard JSON whitespace: space, tab, line feed, carriage return.
  var WHITESPACE = { " ": true, "\t": true, "\n": true, "\r": true };

  // Result helpers ----------------------------------------------------------

  function fail(kind, message, offset) {
    var error = { kind: kind, message: message };
    if (offset !== undefined) error.offset = offset;
    return { ok: false, error: error };
  }

  // Control-flow error carrying a certain UTF-16 offset (optional) and a kind.
  // `kind` is "syntax" (default) or "limit". `offset` is omitted for limits.
  function ParseError(message, offset, kind) {
    this.message = message;
    if (offset !== undefined) this.offset = offset;
    this.kind = kind || "syntax";
  }

  // Throw a limit error (no offset; the position is not a "certain" location).
  function limitError(message) {
    throw new ParseError(message, undefined, "limit");
  }

  function isDigit(c) {
    return c >= "0" && c <= "9";
  }

  function skipWhitespace(s, i) {
    var n = s.length;
    while (i < n && WHITESPACE[s[i]]) i++;
    return i;
  }

  // Running count of (value nodes + object keys). Bumped as each is produced;
  // once it exceeds the cap we bail with a limit error rather than continuing
  // to allocate.
  function bump(ctx) {
    ctx.count++;
    if (ctx.count > MAX_NODES_AND_KEYS) {
      limitError("node/key count exceeds limit " + MAX_NODES_AND_KEYS);
    }
  }

  // Public entry point ------------------------------------------------------

  function parse(source) {
    if (typeof source !== "string") {
      return fail("syntax", "input must be a string");
    }
    var n = source.length;
    var pos = skipWhitespace(source, 0);
    if (pos >= n) {
      // Empty or whitespace-only input is not a JSON value.
      return fail("syntax", "expected a JSON value but reached end of input", n);
    }

    var ctx = { count: 0 };
    var node;
    try {
      // Root value is at container depth 0.
      node = parseValue(source, pos, 0, ctx);
    } catch (e) {
      if (e instanceof ParseError) {
        return fail(e.kind || "syntax", e.message, e.offset);
      }
      throw e; // unexpected non-parser error
    }

    pos = node.pos;
    var end = skipWhitespace(source, pos);
    if (end < n) {
      // A JSON document is exactly one value; anything left over is a syntax error.
      return fail("syntax", "unexpected trailing characters", end);
    }

    delete node.pos; // internal-only field; keep the returned node clean
    return { ok: true, node: node };
  }

  // Value dispatch. `depth` is the number of enclosing containers (root value
  // is depth 0). `ctx` accumulates the node/key count.
  function parseValue(s, i, depth, ctx) {
    var n = s.length;
    if (i >= n) throw new ParseError("unexpected end of input", i);
    var c = s[i];

    // Each value node counts toward the node/key budget.
    bump(ctx);

    if (c === '"') return parseString(s, i);
    if (c === "-" || isDigit(c)) return parseNumber(s, i);
    if (c === "t") return parseKeyword(s, i, "true", "boolean");
    if (c === "f") return parseKeyword(s, i, "false", "boolean");
    if (c === "n") return parseKeyword(s, i, "null", "null");
    if (c === "{") return parseObject(s, i, depth, ctx);
    if (c === "[") return parseArray(s, i, depth, ctx);
    throw new ParseError("unexpected character", i);
  }

  function parseKeyword(s, i, word, type) {
    for (var k = 0; k < word.length; k++) {
      if (s[i + k] !== word[k]) throw new ParseError("invalid literal", i);
    }
    return { type: type, raw: word, pos: i + word.length };
  }

  // Number: keep the exact token; do NOT call Number() or JSON.parse.
  function parseNumber(s, i) {
    var n = s.length;
    var start = i;
    var c;
    if (s[i] === "-") i++;

    // integer part
    if (i >= n) throw new ParseError("unexpected end of number", start);
    c = s[i];
    if (c === "0") {
      i++;
    } else if (isDigit(c)) {
      while (i < n && isDigit(s[i])) i++;
    } else {
      throw new ParseError("invalid number", start);
    }

    // fraction
    if (i < n && s[i] === ".") {
      i++;
      if (i >= n || !isDigit(s[i])) throw new ParseError("invalid number fraction", start);
      while (i < n && isDigit(s[i])) i++;
    }

    // exponent
    if (i < n && (s[i] === "e" || s[i] === "E")) {
      i++;
      if (i < n && (s[i] === "+" || s[i] === "-")) i++;
      if (i >= n || !isDigit(s[i])) throw new ParseError("invalid number exponent", start);
      while (i < n && isDigit(s[i])) i++;
    }

    var raw = s.slice(start, i);
    // Raw token preserved verbatim; no numeric conversion anywhere.
    return { type: "number", raw: raw, pos: i };
  }

  // String: scan to the matching unescaped closing quote, then validate the
  // bounded token with JSON.parse (allowed for a single bounded string token).
  // Returns { raw, value, pos }; the caller decides how to use it (a value node
  // or an object key). This function does not bump the count.
  function parseStringToken(s, i) {
    var n = s.length;
    var start = i; // the opening quote
    i++;
    while (i < n) {
      var c = s[i];
      if (c === '"') {
        var token = s.slice(start, i + 1);
        var value;
        try {
          value = JSON.parse(token);
        } catch (e) {
          // Invalid escape, lone/bad \u, unescaped control char, etc.
          throw new ParseError("invalid string literal", start);
        }
        // `value` is the decoded string; it is data only and is never executed
        // as HTML/JS (the display layer is responsible for text-node escaping).
        return { raw: token, value: value, pos: i + 1 };
      }
      if (c === "\\") {
        // An escape consumes the following character. JSON.parse re-validates the
        // whole escape (e.g. \u needs 4 hex), so scanning one char ahead is enough
        // to avoid being fooled by an escaped quote or backslash.
        i += 2;
        continue;
      }
      i++;
    }
    throw new ParseError("unterminated string literal", start);
  }

  // A string value node. Counts as one node via the parseValue entry bump.
  function parseString(s, i) {
    var tok = parseStringToken(s, i);
    return { type: "string", raw: tok.raw, value: tok.value, pos: tok.pos };
  }

  // Object: `{ "key": value, ... }`. Preserves order and duplicate keys.
  function parseObject(s, i, depth, ctx) {
    // Container nesting depth check (root container is depth 0).
    if (depth > MAX_CONTAINER_DEPTH) {
      limitError("container nesting depth exceeds limit " + MAX_CONTAINER_DEPTH);
    }
    var n = s.length;
    var entries = [];
    i++; // skip '{'
    i = skipWhitespace(s, i);
    if (i >= n) throw new ParseError("unterminated object", i);
    if (s[i] === '}') {
      return { type: "object", entries: entries, pos: i + 1 };
    }

    while (true) {
      i = skipWhitespace(s, i);
      if (i >= n) throw new ParseError("unterminated object (expected property name)", i);
      if (s[i] !== '"') {
        throw new ParseError("expected string key", i);
      }

      // A key is a string token; it counts as an object key (not a value node).
      bump(ctx);
      var keyTok = parseStringToken(s, i);
      var key = keyTok.value;
      var rawKey = keyTok.raw;
      i = skipWhitespace(s, keyTok.pos);

      if (i >= n || s[i] !== ':') {
        throw new ParseError("expected ':' after object key", i);
      }
      i++; // skip ':'
      i = skipWhitespace(s, i);
      if (i >= n) {
        throw new ParseError("unterminated object (expected value)", i);
      }
      var value = parseValue(s, i, depth + 1, ctx);
      var pos = value.pos;
      delete value.pos; // consume the internal position, keep the tree clean
      entries.push({ key: key, rawKey: rawKey, value: value });

      i = skipWhitespace(s, pos);
      if (i >= n) {
        throw new ParseError("unterminated object (expected ',' or '}')", i);
      }
      var ch = s[i];
      if (ch === '}') {
        return { type: "object", entries: entries, pos: i + 1 };
      }
      if (ch === ',') {
        i++;
        i = skipWhitespace(s, i);
        // A trailing comma (nothing but '}' after it) is invalid JSON.
        if (i >= n || s[i] === '}') {
          throw new ParseError("trailing comma in object", i >= n ? n : i);
        }
        continue;
      }
      throw new ParseError("expected ',' or '}' in object", i);
    }
  }

  // Array: `[ value, ... ]`. Preserves item order.
  function parseArray(s, i, depth, ctx) {
    if (depth > MAX_CONTAINER_DEPTH) {
      limitError("container nesting depth exceeds limit " + MAX_CONTAINER_DEPTH);
    }
    var n = s.length;
    var items = [];
    i++; // skip '['
    i = skipWhitespace(s, i);
    if (i >= n) throw new ParseError("unterminated array", i);
    if (s[i] === ']') {
      return { type: "array", items: items, pos: i + 1 };
    }

    while (true) {
      i = skipWhitespace(s, i);
      if (i >= n) {
        throw new ParseError("unterminated array (expected value)", i);
      }
      var item = parseValue(s, i, depth + 1, ctx);
      var ipos = item.pos;
      delete item.pos; // consume the internal position, keep the tree clean
      items.push(item);

      i = skipWhitespace(s, ipos);
      if (i >= n) {
        throw new ParseError("unterminated array (expected ',' or ']')", i);
      }
      var ach = s[i];
      if (ach === ']') {
        return { type: "array", items: items, pos: i + 1 };
      }
      if (ach === ',') {
        i++;
        i = skipWhitespace(s, i);
        if (i >= n || s[i] === ']') {
          throw new ParseError("trailing comma in array", i >= n ? n : i);
        }
        continue;
      }
      throw new ParseError("expected ',' or ']' in array", i);
    }
  }

  // Expose as globalThis.MDPJSON (window in the browser, global in Node).
  var MDPJSON = {
    parse: parse,
    limits: {
      maxContainerDepth: MAX_CONTAINER_DEPTH,
      maxNodesAndKeys: MAX_NODES_AND_KEYS
    }
  };
  if (root && typeof root === "object") root.MDPJSON = MDPJSON;
  // For Node/test loading.
  if (typeof module !== "undefined" && module.exports) module.exports = MDPJSON;
})(typeof globalThis !== "undefined" ? globalThis : this);
