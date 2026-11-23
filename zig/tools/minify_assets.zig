const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Build-time zero-dependency asset bundler, JS/CSS/HTML minifier, ETag calculator,
/// and gzip pre-compressor. Generates `embedded_assets.zig` consumed by `zig/runtime/server.zig`.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // Args: <out_zig_path> <signals.js> <client.js> <dom.js> <analytics.js> <monitor.js> <dash.html> <dash.css> <dash.js>
    if (args.len < 10) {
        std.debug.print("usage: minify_assets <out.zig> <signals.js> <client.js> <dom.js> <analytics.js> <monitor.js> <dash.html> <dash.css> <dash.js>\n", .{});
        std.process.exit(2);
    }

    const out_path = args[1];
    const signals_src = try readFile(gpa, io, args[2]);
    defer gpa.free(signals_src);
    const client_src = try readFile(gpa, io, args[3]);
    defer gpa.free(client_src);
    const dom_src = try readFile(gpa, io, args[4]);
    defer gpa.free(dom_src);
    const analytics_src = try readFile(gpa, io, args[5]);
    defer gpa.free(analytics_src);
    const monitor_src = try readFile(gpa, io, args[6]);
    defer gpa.free(monitor_src);
    const dash_html_src = try readFile(gpa, io, args[7]);
    defer gpa.free(dash_html_src);
    const dash_css_src = try readFile(gpa, io, args[8]);
    defer gpa.free(dash_css_src);
    const dash_js_src = try readFile(gpa, io, args[9]);
    defer gpa.free(dash_js_src);

    // Bundle `signals.js` + `client.js` + `dom.js` into a single zero-waterfall ESM file for `/_concave/index.js`.
    const bundle_src = try bundleCoreClient(gpa, signals_src, client_src, dom_src);
    defer gpa.free(bundle_src);

    const bundle_min = try minifyJs(gpa, bundle_src);
    defer gpa.free(bundle_min);
    const signals_min = try minifyJs(gpa, signals_src);
    defer gpa.free(signals_min);
    const client_min = try minifyJs(gpa, client_src);
    defer gpa.free(client_min);
    const dom_min = try minifyJs(gpa, dom_src);
    defer gpa.free(dom_min);
    const analytics_min = try minifyJs(gpa, analytics_src);
    defer gpa.free(analytics_min);
    const monitor_min = try minifyJs(gpa, monitor_src);
    defer gpa.free(monitor_min);
    const dash_html_min = try minifyHtml(gpa, dash_html_src);
    defer gpa.free(dash_html_min);
    const dash_css_min = try minifyCss(gpa, dash_css_src);
    defer gpa.free(dash_css_min);
    const dash_js_min = try minifyJs(gpa, dash_js_src);
    defer gpa.free(dash_js_min);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll(
        \\// Auto-generated at build time by `zig/tools/minify_assets.zig`.
        \\// Contains bundled, minified, and pre-gzipped embedded browser assets + strong ETags.
        \\
        \\pub const Asset = struct {
        \\    raw: []const u8,
        \\    gzip: []const u8,
        \\    etag: []const u8,
        \\    content_type: []const u8,
        \\};
        \\
        \\
    );

    try emitAsset(gpa, w, "client_index_js", bundle_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "client_signals_js", signals_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "client_client_js", client_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "client_dom_js", dom_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "analytics_client_js", analytics_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "monitor_client_js", monitor_min, "text/javascript; charset=utf-8");
    try emitAsset(gpa, w, "dashboard_index_html", dash_html_min, "text/html; charset=utf-8");
    try emitAsset(gpa, w, "dashboard_styles_css", dash_css_min, "text/css; charset=utf-8");
    try emitAsset(gpa, w, "dashboard_app_js", dash_js_min, "text/javascript; charset=utf-8");

    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    const f = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, out.written(), 0);
}

fn readFile(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

fn bundleCoreClient(allocator: Allocator, signals_src: []const u8, client_src: []const u8, dom_src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, signals_src);
    try out.append(allocator, '\n');
    try appendWithoutRelativeSignalsImport(allocator, &out, client_src);
    try out.append(allocator, '\n');
    try appendWithoutRelativeSignalsImport(allocator, &out, dom_src);
    return try out.toOwnedSlice(allocator);
}

fn appendWithoutRelativeSignalsImport(allocator: Allocator, out: *std.ArrayList(u8), src: []const u8) !void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "import ") and std.mem.indexOf(u8, trimmed, "./signals.js") != null) {
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

fn gzipBest(allocator: Allocator, input: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @max(@as(usize, 128), input.len + 64));
    errdefer out.deinit();
    var window_buf: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&out.writer, &window_buf, .gzip, .best);
    try comp.writer.writeAll(input);
    try comp.finish();
    return try out.toOwnedSlice();
}

fn emitAsset(allocator: Allocator, w: *std.Io.Writer, name: []const u8, raw: []const u8, content_type: []const u8) !void {
    const gz = try gzipBest(allocator, raw);
    defer allocator.free(gz);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    const etag_hex = std.fmt.bytesToHex(digest[0..8], .lower);

    try w.print("pub const {s}: Asset = .{{\n", .{name});
    try w.writeAll("    .raw = ");
    try writeZigBytesLiteral(w, raw);
    try w.writeAll(",\n    .gzip = ");
    try writeZigBytesLiteral(w, gz);
    try w.print(",\n    .etag = \"\\\"{s}\\\"\",\n", .{etag_hex});
    try w.print("    .content_type = \"{s}\",\n}};\n\n", .{content_type});
}

fn writeZigBytesLiteral(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        if (b >= 0x20 and b <= 0x7e and b != '"' and b != '\\') {
            try w.writeByte(b);
        } else {
            try w.writeAll("\\x");
            try w.writeByte(hex[b >> 4]);
            try w.writeByte(hex[b & 0x0f]);
        }
    }
    try w.writeByte('"');
}

/// Safe lexical JavaScript minifier:
/// - Preserves single/double strings, nested template literals (`...${...}...`), and regex literals.
/// - Strips `//` and `/* ... */` comments and collapses redundant whitespace.
/// - Preserves newlines whenever required for JavaScript Automatic Semicolon Insertion (ASI).
pub fn minifyJs(allocator: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var had_space = false;
    var had_newline = false;
    var prev_token: PrevToken = .none;
    // Track nested template literal `${ ... }` brace depths.
    var tpl_braces: std.ArrayList(usize) = .empty;
    defer tpl_braces.deinit(allocator);
    var brace_depth: usize = 0;

    while (i < src.len) {
        const c = src[i];

        // Whitespace
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (c == '\n') had_newline = true;
            had_space = true;
            i += 1;
            continue;
        }

        // Line comment `//...`
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }

        // Block comment `/*...*/`
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) {
                if (src[i] == '\n') had_newline = true;
                i += 1;
            }
            if (i + 1 < src.len) i += 2;
            had_space = true;
            continue;
        }

        // String literal `'...'` or `"..."`
        if (c == '\'' or c == '"') {
            try emitSep(allocator, &out, prev_token, .literal, had_space, had_newline);
            had_space = false;
            had_newline = false;
            const quote = c;
            try out.append(allocator, c);
            i += 1;
            while (i < src.len) {
                const sc = src[i];
                try out.append(allocator, sc);
                i += 1;
                if (sc == '\\' and i < src.len) {
                    try out.append(allocator, src[i]);
                    i += 1;
                } else if (sc == quote) {
                    break;
                }
            }
            prev_token = .literal;
            continue;
        }

        // Template literal `` `...` ``
        if (c == '`') {
            try emitSep(allocator, &out, prev_token, .literal, had_space, had_newline);
            had_space = false;
            had_newline = false;
            try out.append(allocator, '`');
            i += 1;
            const entered_expr = try scanTemplateBody(allocator, &out, src, &i);
            if (entered_expr) {
                try tpl_braces.append(allocator, brace_depth);
                brace_depth += 1;
                prev_token = .punct_open;
            } else {
                prev_token = .literal;
            }
            continue;
        }

        // Closing `}` of a template expression `${ ... }` -> resume template literal body!
        if (c == '}' and tpl_braces.items.len > 0 and brace_depth == tpl_braces.items[tpl_braces.items.len - 1] + 1) {
            brace_depth -= 1;
            _ = tpl_braces.pop();
            had_space = false;
            had_newline = false;
            try out.append(allocator, '}');
            i += 1;
            const entered_expr = try scanTemplateBody(allocator, &out, src, &i);
            if (entered_expr) {
                try tpl_braces.append(allocator, brace_depth);
                brace_depth += 1;
                prev_token = .punct_open;
            } else {
                prev_token = .literal;
            }
            continue;
        }

        // Regex literal `/pattern/flags` when `/` appears in expression-start position
        if (c == '/' and canStartRegex(prev_token)) {
            try emitSep(allocator, &out, prev_token, .literal, had_space, had_newline);
            had_space = false;
            had_newline = false;
            try out.append(allocator, '/');
            i += 1;
            var in_class = false;
            while (i < src.len) {
                const rc = src[i];
                try out.append(allocator, rc);
                i += 1;
                if (rc == '\\' and i < src.len) {
                    try out.append(allocator, src[i]);
                    i += 1;
                } else if (rc == '[') {
                    in_class = true;
                } else if (rc == ']') {
                    in_class = false;
                } else if (rc == '/' and !in_class) {
                    break;
                }
            }
            while (i < src.len and isIdentPart(src[i])) {
                try out.append(allocator, src[i]);
                i += 1;
            }
            prev_token = .literal;
            continue;
        }

        // Identifier / keyword / number
        if (isIdentStart(c) or (c >= '0' and c <= '9')) {
            const start = i;
            if (isIdentStart(c)) {
                i += 1;
                while (i < src.len and isIdentPart(src[i])) i += 1;
            } else {
                i += 1;
                while (i < src.len and (isIdentPart(src[i]) or src[i] == '.')) i += 1;
            }
            const word = src[start..i];
            const kind: PrevToken = if (isWordOpOrKeywordBeforeRegex(word)) .keyword_expr else .ident;
            try emitSep(allocator, &out, prev_token, kind, had_space, had_newline);
            had_space = false;
            had_newline = false;
            try out.appendSlice(allocator, word);
            prev_token = kind;
            continue;
        }

        // Punctuation & operators
        if (c == '{') brace_depth += 1 else if (c == '}' and brace_depth > 0) brace_depth -= 1;

        const pkind: PrevToken = switch (c) {
            ')', ']' => .punct_close,
            '}' => .brace_close,
            '(', '[', '{', ',', ';', ':', '?', '~', '!' => .punct_open,
            '+' => .plus,
            '-' => .minus,
            else => .op,
        };
        try emitSep(allocator, &out, prev_token, pkind, had_space, had_newline);
        had_space = false;
        had_newline = false;
        try out.append(allocator, c);
        i += 1;
        prev_token = pkind;
    }

    return try out.toOwnedSlice(allocator);
}

const PrevToken = enum {
    none,
    ident,
    keyword_expr,
    literal,
    punct_open,
    punct_close,
    brace_close,
    plus,
    minus,
    op,
};

fn canStartRegex(prev: PrevToken) bool {
    return switch (prev) {
        .none, .keyword_expr, .punct_open, .brace_close, .plus, .minus, .op => true,
        .ident, .literal, .punct_close => false,
    };
}

fn emitSep(allocator: Allocator, out: *std.ArrayList(u8), prev: PrevToken, next: PrevToken, had_space: bool, had_newline: bool) !void {
    if (prev == .none) return;
    const prev_word = (prev == .ident or prev == .keyword_expr or prev == .literal);
    const next_word = (next == .ident or next == .keyword_expr or next == .literal);

    // Prevent token merging: `return x`, `a + +b`, `a - -b`
    if (had_space) {
        if ((prev == .plus and next == .plus) or (prev == .minus and next == .minus)) {
            try out.append(allocator, ' ');
            return;
        }
    }
    // Preserve newline when ASI could be affected (between statement-ending token and next token)
    if (had_newline) {
        const can_end_stmt = (prev == .ident or prev == .keyword_expr or prev == .literal or prev == .punct_close or prev == .brace_close or prev == .plus or prev == .minus);
        const needs_nl = can_end_stmt and (next_word or next == .punct_open or next == .plus or next == .minus);
        if (needs_nl) {
            try out.append(allocator, '\n');
            return;
        }
    }
    if (prev_word and next_word) {
        try out.append(allocator, ' ');
    }
}

fn scanTemplateBody(allocator: Allocator, out: *std.ArrayList(u8), src: []const u8, i: *usize) !bool {
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == '\\' and i.* + 1 < src.len) {
            try out.append(allocator, c);
            try out.append(allocator, src[i.* + 1]);
            i.* += 2;
        } else if (c == '`') {
            try out.append(allocator, '`');
            i.* += 1;
            return false;
        } else if (c == '$' and i.* + 1 < src.len and src[i.* + 1] == '{') {
            try out.appendSlice(allocator, "${");
            i.* += 2;
            return true;
        } else {
            try out.append(allocator, c);
            i.* += 1;
        }
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isWordOpOrKeywordBeforeRegex(word: []const u8) bool {
    const kws = [_][]const u8{
        "return", "case", "throw", "in", "of", "typeof", "void", "delete", "new", "else", "do", "yield", "await",
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

pub fn minifyCss(allocator: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var pending_space = false;
    while (i < src.len) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            if (i + 1 < src.len) i += 2;
            continue;
        }
        if (c == '"' or c == '\'') {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            const q = c;
            try out.append(allocator, q);
            i += 1;
            while (i < src.len) {
                const sc = src[i];
                try out.append(allocator, sc);
                i += 1;
                if (sc == '\\' and i < src.len) {
                    try out.append(allocator, src[i]);
                    i += 1;
                } else if (sc == q) break;
            }
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            pending_space = true;
            i += 1;
            continue;
        }
        const is_punct = (c == '{' or c == '}' or c == ':' or c == ';' or c == ',' or c == '>' or c == '+' or c == '~');
        if (is_punct) {
            // Drop trailing semicolon right before `}`
            if (c == '}' and out.items.len > 0 and out.items[out.items.len - 1] == ';') {
                _ = out.pop();
            }
            pending_space = false;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (pending_space and out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            const last_punct = (last == '{' or last == '}' or last == ':' or last == ';' or last == ',' or last == '>' or last == '+' or last == '~');
            if (!last_punct) try out.append(allocator, ' ');
        }
        pending_space = false;
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn minifyHtml(allocator: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var pending_space = false;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, src, i + 4, "-->")) |end| {
                i = end + 3;
                continue;
            }
        }
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space and out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            if (!(last == '>' and c == '<')) {
                try out.append(allocator, ' ');
            }
        }
        pending_space = false;
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}
