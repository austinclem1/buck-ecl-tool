const std = @import("std");

const Allocator = std.mem.Allocator;

const CommandTag = @import("CommandTag.zig").Tag;

pub const Token = struct {
    location: usize,
    variant: Variant,

    pub const Variant = union(enum) {
        identifier: []const u8,
        number: u32,
        string: []const u8,
        command: CommandTag,
        keyword_BYTES,
        keyword_byte,
        keyword_word,
        keyword_dword,
        keyword_pointer,
        keyword_b,
        keyword_w,
        keyword_d,
        keyword_header,
        keyword_var,
        newline,
        colon,
        lsquare_bracket,
        rsquare_bracket,
        at_sign,
        equals,
        eof,
    };

    pub fn toString(tag: std.meta.Tag(Variant)) []const u8 {
        return switch (tag) {
            .identifier => "identifier",
            .number => "number literal",
            .string => "string",
            .command => "command",
            .keyword_BYTES => "\"BYTES\"",
            .keyword_byte => "\"byte\"",
            .keyword_word => "\"word\"",
            .keyword_dword => "\"dword\"",
            .keyword_pointer => "\"pointer\"",
            .keyword_b => "\"b\"",
            .keyword_w => "\"w\"",
            .keyword_d => "\"d\"",
            .keyword_header => "\"header\"",
            .keyword_var => "\"var\"",
            .newline => "newline",
            .colon => "\":\"",
            .lsquare_bracket => "\"[\"",
            .rsquare_bracket => "\"]\"",
            .at_sign => "\"@\"",
            .equals => "\"=\"",
            .eof => "EOF",
        };
    }
};

pub const TokenStream = struct {
    tokens: []const Token,
    current: usize,

    pub fn next(self: *TokenStream) Token {
        const tok = self.tokens[self.current];
        self.current += 1;
        return tok;
    }

    pub fn peek(self: *TokenStream) Token {
        return self.tokens[self.current];
    }

    pub fn peekN(self: *TokenStream, n: usize) Token {
        return self.tokens[self.current + n];
    }

    pub fn eatAny(self: *TokenStream, to_eat: std.meta.Tag(Token.Variant)) void {
        while (self.current < self.tokens.len) : (self.current += 1) {
            if (std.meta.activeTag(self.tokens[self.current].variant) != to_eat) return;
        }
    }

    pub fn free(self: *TokenStream, allocator: Allocator) void {
        allocator.free(self.tokens);
        self.* = undefined;
    }
};

pub fn tokenize(allocator: Allocator, buffer: []const u8) error{ TokenizationFailed, OutOfMemory }!TokenStream {
    var tokens = std.array_list.Managed(Token).init(allocator);
    defer tokens.deinit();

    var pos: usize = 0;

    while (pos < buffer.len) {
        switch (buffer[pos]) {
            'a'...'z', 'A'...'Z', '_' => {
                const read, const tok = readIdentifierOrKeyword(buffer[pos..]);
                try tokens.append(.{ .location = pos, .variant = tok });
                pos += read;
            },
            '0'...'9' => {
                var err_info: ?ReadNumberErrorInfo = null;
                if (readNumber(buffer[pos..], &err_info)) |result| {
                    const read, const tok = result;
                    try tokens.append(.{ .location = pos, .variant = tok });
                    pos += read;
                } else |err| switch (err) {
                    error.Overflow => {
                        std.debug.print("error: Number literal too large for max size of 32 bits (file offset {d})", .{pos});
                        return error.TokenizationFailed;
                    },
                    error.InvalidCharacter => {
                        const invalid_char_pos = pos + err_info.?.invalid_char_offset;
                        std.debug.print("error: Encountered invalid character while parsing number literal (file offset {d})", .{invalid_char_pos});
                        return error.TokenizationFailed;
                    },
                }
            },
            ':' => {
                try tokens.append(.{ .location = pos, .variant = .colon });
                pos += 1;
            },
            '[' => {
                try tokens.append(.{ .location = pos, .variant = .lsquare_bracket });
                pos += 1;
            },
            ']' => {
                try tokens.append(.{ .location = pos, .variant = .rsquare_bracket });
                pos += 1;
            },
            '=' => {
                try tokens.append(.{ .location = pos, .variant = .equals });
                pos += 1;
            },
            '@' => {
                try tokens.append(.{ .location = pos, .variant = .at_sign });
                pos += 1;
            },
            ' ', '\t', '\r', '\n' => {
                const read, const found_newline = eatWhitespace(buffer[pos..]);
                if (found_newline) try tokens.append(.{ .location = pos, .variant = .newline });
                pos += read;
            },
            '#' => {
                const read, const found_newline = eatComment(buffer[pos..]);
                if (found_newline) try tokens.append(.{ .location = pos, .variant = .newline });
                pos += read;
            },
            '"' => {
                if (readString(buffer[pos..])) |result| {
                    const read, const string = result;
                    try tokens.append(.{ .location = pos, .variant = .{ .string = string } });
                    pos += read;
                } else |err| switch (err) {
                    error.NoClosingQuote => {
                        std.debug.print("error: No matching quote found for string starting at byte {d}", .{pos});
                        return error.TokenizationFailed;
                    },
                }
            },
            else => {
                std.debug.print("error: Encountered invalid character '{c}' at byte {d}\n", .{ buffer[pos], pos });
                return error.TokenizationFailed;
            },
        }
    }

    std.debug.assert(pos == buffer.len);

    try tokens.append(.{ .location = pos, .variant = .eof });

    return TokenStream{
        .tokens = try tokens.toOwnedSlice(),
        .current = 0,
    };
}

fn readIdentifierOrKeyword(buffer: []const u8) struct { usize, Token.Variant } {
    var pos: usize = 0;
    while (pos < buffer.len) : (pos += 1) {
        switch (buffer[pos]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => break,
        }
    }

    const str = buffer[0..pos];

    const tok = blk: {
        if (command_tag_map.get(str)) |command_tag| {
            break :blk Token.Variant{ .command = command_tag };
        } else if (keyword_map.get(str)) |keyword_tok| {
            break :blk keyword_tok;
        } else {
            break :blk Token.Variant{ .identifier = str }; // should we dupe this?
        }
    };

    return .{ pos, tok };
}

const ReadNumberErrorInfo = union(enum) {
    invalid_char_offset: usize,
};

const ReadNumberError = error{
    InvalidCharacter,
    Overflow,
};

fn readNumber(buffer: []const u8, err_info_out: *?ReadNumberErrorInfo) ReadNumberError!struct { usize, Token.Variant } {
    var pos: usize = 0;

    var radix: u32 = 10;
    if (std.mem.startsWith(u8, buffer, "0x")) {
        pos += 2;
        radix = 16;
    }

    // TODO: handle negative literals
    var val: u32 = 0;
    while (pos < buffer.len) : (pos += 1) {
        const ch = buffer[pos];
        switch (ch) {
            '\n', '\t', '\r', ' ' => break,
            '0'...'9' => {
                val = try std.math.mul(u32, val, radix);
                val = try std.math.add(u32, val, ch - '0');
            },
            'a'...'f' => {
                if (radix != 16) {
                    err_info_out.* = .{ .invalid_char_offset = pos };
                    return error.InvalidCharacter;
                }
                val = try std.math.mul(u32, val, radix);
                val = try std.math.add(u32, val, (ch - 'a') + 10);
            },
            else => break,
            // TODO what is valid after this, math op characters etc? Not other things?
            // else => {
            //     err_info_out.* = .{ .invalid_char_offset = pos };
            //     return error.InvalidCharacter;
            // },
        }
    }

    // TODO what if someone just wrote "0x" and whitespace after?

    return .{ pos, .{ .number = val } };
}

fn eatWhitespace(buffer: []const u8) struct { usize, bool } {
    var found_newline = false;

    var pos: usize = 0;
    while (pos < buffer.len) : (pos += 1) {
        switch (buffer[pos]) {
            ' ', '\t', '\r' => {},
            '\n' => found_newline = true,
            else => {
                break;
            },
        }
    }

    return .{ pos, found_newline };
}

fn eatComment(buffer: []const u8) struct { usize, bool } {
    var found_newline = false;

    var pos: usize = 0;
    while (pos < buffer.len) : (pos += 1) {
        switch (buffer[pos]) {
            '\n' => {
                found_newline = true;
                break;
            },
            else => {},
        }
    }

    return .{ pos, found_newline };
}

fn readString(buffer: []const u8) !struct { usize, []const u8 } {
    std.debug.assert(buffer[0] == '"');

    if (buffer.len < 2) {
        return error.NoClosingQuote;
    }

    for (buffer[1..], 1..) |ch, i| {
        switch (ch) {
            '"' => {
                const str_bytes = buffer[1..i];
                // add 1 to read amount to account for closing quote character
                return .{ i + 1, str_bytes };
            },
            '\n' => return error.NoClosingQuote,
            else => {},
        }
    }

    return error.NoClosingQuote;
}

const command_tag_map = std.StaticStringMap(CommandTag).initComptime(command_tag_map_kvs);
const command_tag_map_kvs = blk: {
    const KV = struct { []const u8, CommandTag };
    var result: [std.enums.values(CommandTag).len]KV = undefined;

    for (std.enums.values(CommandTag), 0..) |e, i| {
        result[i] = .{ @tagName(e), e };
    }

    break :blk result;
};

const keyword_map = std.StaticStringMap(Token.Variant).initComptime(.{
    .{ "BYTES", .keyword_BYTES },
    .{ "byte", .keyword_byte },
    .{ "word", .keyword_word },
    .{ "dword", .keyword_dword },
    .{ "pointer", .keyword_pointer },
    .{ "b", .keyword_b },
    .{ "w", .keyword_w },
    .{ "d", .keyword_d },
    .{ "header", .keyword_header },
    .{ "var", .keyword_var },
});
