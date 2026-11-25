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
//   location cannot be stated reliably.
//
// Node shapes produced by this version (step 10: primitive values only):
//   { type: "string",  raw: <raw quoted token>, value: <decoded string> }
//   { type: "number",  raw: <exact source token> }   // NOT a JS number
//   { type: "boolean", raw: "true" | "false" }
//   { type: "null",    raw: "null" }
//
// Precision: a number node keeps the exact source token and is never converted
// with Number()/JSON.parse, so large integers and high-precision decimals
// survive without floating-point round-tripping. String tokens are validated by
// parsing the *bounded* token with JSON.parse (explicitly allowed for a single
// already-bounded string token); the whole source and numbers are never handed
// to JSON.parse.
//
// Scope note: objects and arrays (and the container depth / node resource limits
// that return "limit" errors) are step 11. A container is reported as a syntax
// error here so the module stays correct and testable on its own. Step 12 wires
// this parser into the preview.

(function (root) {
  "use strict";

  // Standard JSON whitespace: space, tab, line feed, carriage return.
  var WHITESPACE = { " ": true, "\t": true, "\n": true, "\r": true };

  // Result helpers ----------------------------------------------------------

  function fail(kind, message, offset) {
    var error = { kind: kind, message: message };
    if (offset !== undefined) error.offset = offset;
    return { ok: false, error: error };
  }

  // Control-flow error carrying a certain UTF-16 offset; caught once in parse().
  function ParseError(message, offset) {
    this.message = message;
    this.offset = offset;
  }

  function isDigit(c) {
    return c >= "0" && c <= "9";
  }

  function skipWhitespace(s, i) {
    var n = s.length;
    while (i < n && WHITESPACE[s[i]]) i++;
    return i;
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

    var node;
    try {
      node = parseValue(source, pos);
    } catch (e) {
      if (e instanceof ParseError) {
        return fail("syntax", e.message, e.offset);
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

  // Value dispatch (primitives only in this version) ------------------------

  function parseValue(s, i) {
    var c = s[i];
    if (c === '"') return parseString(s, i);
    if (c === "-" || (c >= "0" && c <= "9")) return parseNumber(s, i);
    if (c === "t") return parseKeyword(s, i, "true", "boolean");
    if (c === "f") return parseKeyword(s, i, "false", "boolean");
    if (c === "n") return parseKeyword(s, i, "null", "null");
    if (c === "{" || c === "[") {
      // Objects and arrays are step 11; primitives-only here.
      throw new ParseError(
        c === "{"
          ? "object parsing is not supported in this module version"
          : "array parsing is not supported in this module version",
        i
      );
    }
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
  function parseString(s, i) {
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
        return { type: "string", raw: token, value: value, pos: i + 1 };
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

  // Expose as globalThis.MDPJSON (window in the browser, global in Node).
  var MDPJSON = { parse: parse };
  if (root && typeof root === "object") root.MDPJSON = MDPJSON;
  // For Node/test loading.
  if (typeof module !== "undefined" && module.exports) module.exports = MDPJSON;
})(typeof globalThis !== "undefined" ? globalThis : this);
