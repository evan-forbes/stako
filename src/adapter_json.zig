const std = @import("std");

pub fn stripEol(raw: []const u8) []const u8 {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

/// Find the value of a top-level (depth==1) string key in a JSON object.
pub fn findStringValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var i: usize = 0;
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            if (depth == 1 and std.mem.startsWith(u8, src[i..], key_with_colon)) {
                var j = i + key_with_colon.len;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                if (j >= src.len or src[j] != '"') return null;
                j += 1;
                const start = j;
                while (j < src.len) : (j += 1) {
                    if (src[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (src[j] == '"') return src[start..j];
                }
                return null;
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

pub const findTopLevelStringValue = findStringValue;

pub fn findIntValue(src: []const u8, key_with_colon: []const u8) ?i64 {
    var i: usize = 0;
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            if (depth == 1 and std.mem.startsWith(u8, src[i..], key_with_colon)) {
                var j = i + key_with_colon.len;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                const start = j;
                while (j < src.len and (std.ascii.isDigit(src[j]) or src[j] == '-')) j += 1;
                return std.fmt.parseInt(i64, src[start..j], 10) catch null;
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

pub fn findObjectValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var i: usize = 0;
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            if (depth == 1 and std.mem.startsWith(u8, src[i..], key_with_colon)) {
                var j = i + key_with_colon.len;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                if (j >= src.len or src[j] != '{') return null;
                const end = findMatchingBraceEnd(src, j) orelse return null;
                return src[j..end];
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

pub fn findArrayValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var i: usize = 0;
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            if (depth == 1 and std.mem.startsWith(u8, src[i..], key_with_colon)) {
                var j = i + key_with_colon.len;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                if (j >= src.len or src[j] != '[') return null;
                const start = j;
                var adepth: usize = 0;
                var ain_str = false;
                var aescape = false;
                while (j < src.len) : (j += 1) {
                    const ac = src[j];
                    if (aescape) {
                        aescape = false;
                        continue;
                    }
                    if (ain_str) {
                        if (ac == '\\') {
                            aescape = true;
                        } else if (ac == '"') {
                            ain_str = false;
                        }
                        continue;
                    }
                    if (ac == '"') {
                        ain_str = true;
                        continue;
                    }
                    if (ac == '[') adepth += 1;
                    if (ac == ']') {
                        adepth -= 1;
                        if (adepth == 0) return src[start .. j + 1];
                    }
                }
                return null;
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

pub fn findMatchingBraceEnd(src: []const u8, start: usize) ?usize {
    if (start >= src.len or src[start] != '{') return null;
    var depth: usize = 0;
    var i = start;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

pub fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

pub fn writeParsedJsonStringContent(w: anytype, s: []const u8) !void {
    try w.writeAll(s);
}
