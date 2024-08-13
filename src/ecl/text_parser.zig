const TextParser = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

const CommandTag = @import("CommandTag.zig").Tag;
const VarType = @import("VarType.zig").VarType;
const IndexSlice = @import("../IndexSlice.zig");

const Token = union(enum) {
    identifier: []const u8,
    number: u32,
    string: []const u8,
    command: CommandTag,
    keyword_BYTES,
    newline,
    colon,
    lsquare_bracket,
    rsquare_bracket,
    at_sign,
    equals,
};

arena: std.heap.ArenaAllocator,
labels_set: std.StringArrayHashMap(void), // index of each label is associated block index
commands: std.ArrayList(Command),
args: std.ArrayList(Arg),

pub fn init(allocator: Allocator) TextParser {
    _ = allocator;
    return .{};
}

pub fn deinit(self: *TextParser) void {
    self.labels_set.deinit();
    // self.init_segments_set.deinit();
    self.arena.deinit();

    self.* = undefined;
}

pub fn parse(self: *TextParser, text: []const u8) !Ast {
    const tokens = try tokenize(text);
    _ = tokens;
    _ = self;

    return .{};
}

const Tokenizer = struct {
    buffer: []const u8,
    pos: usize,

    pub fn eatWhitespace(self: *Tokenizer) struct { usize, bool } {
        var found_newline = false;

        const start = self.pos;
        var end = start;
        while (end < self.buffer.len) {
            const ch = self.buffer[end];
            switch (ch) {
                ' ', '\t', '\r' => end += 1,
                '\n' => {
                    found_newline = true;
                    end += 1;
                },
                else => break,
            }
        }

        return .{ end - start, found_newline };
    }

    pub fn readToken(self: *Tokenizer) ?Token {
        while (self.pos < self.buffer.len) {
            switch (self.buffer[self.pos]) {
                'a'...'z', 'A'...'Z', '_' => {
                    const read, const tok = self.readIdentifierOrKeyword();
                    self.pos += read;
                    return tok;
                },
                '0'...'9' => {
                    const read, const tok = self.readNumber();
                    self.pos += read;
                    return tok;
                },
                ':' => {
                    self.pos += 1;
                    return .colon;
                },
                '[' => {
                    self.pos += 1;
                    return .lsquare_bracket;
                },
                ']' => {
                    self.pos += 1;
                    return .rsquare_bracket;
                },
                '=' => {
                    self.pos += 1;
                    return .equals;
                },
                '@' => {
                    self.pos += 1;
                    return .at_sign;
                },
                ' ', '\t', '\r', '\n' => {
                    const read, const found_newline = self.eatWhitespace();
                    self.pos += read;
                    if (found_newline) return .newline;
                },
                else => {
                    // TODO: error on invalid character
                    self.pos += 1;
                },
            }
        }

        return null;
    }

    fn readIdentifierOrKeyword(self: *Tokenizer) struct { usize, Token } {
        const start = self.pos;
        var end = start;
        while (end < self.buffer.len) : (end += 1) {
            const ch = self.buffer[end];
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => break,
            }
        }

        const str = self.buffer[start..end];
        if (command_tag_map.get(str)) |command_tag| {
            return .{ str.len, .{ .command = command_tag } };
        }
        if (std.mem.eql(u8, str, "BYTES")) {
            return .{ str.len, .keyword_BYTES };
        }
        return .{ str.len, .{ .identifier = str } };
    }

    fn readNumber(self: *Tokenizer) struct { usize, Token } {
        const start = self.pos;
        var end = start;

        var radix: u32 = 10;
        if (std.mem.startsWith(u8, self.buffer[start..], "0x")) {
            end += 2;
            radix = 16;
        }

        var val: u32 = 0;
        while (end < self.buffer.len) {
            const ch = self.buffer[end];
            switch (ch) {
                '0'...'9' => {
                    // TODO: handle overflow
                    val *= radix;
                    val += (ch - '0');
                    end += 1;
                },
                else => break,
            }
        }

        return .{ end - start, .{ .number = val } };
    }
};

pub fn tokenize(allocator: Allocator, text: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    defer tokens.deinit();

    var tokenizer = Tokenizer{ .pos = 0, .buffer = text };
    while (tokenizer.readToken()) |tok| {
        try tokens.append(tok);
    }

    return tokens.toOwnedSlice();
}

fn expectBlock(self: *TextParser) !Block {
    _ = self;
}
// expect header
// expect label
// accept var decl
// accept label or command or initialized bytes
// accept arg
fn acceptArg(self: *TextParser) ?Arg {
    _ = self;
    return null;
}

const Block = struct {
    label: []const u8,
    commands: IndexSlice,
};

const command_tag_map = blk: {
    @setEvalBranchQuota(2500);
    break :blk std.ComptimeStringMap(CommandTag, command_tag_map_kvs);
};
const command_tag_map_kvs = blk: {
    const KV = struct { []const u8, CommandTag };
    var result: [std.enums.values(CommandTag).len]KV = undefined;

    for (std.enums.values(CommandTag), 0..) |e, i| {
        result[i] = .{ @tagName(e), e };
    }

    break :blk result;
};

const State = enum {
    start,
    parsing_decls,
    parsing_header,
    parsing_block,
    parsing_command_args,
    parsing_identifier,
};

const Command = struct {
    tag: CommandTag,
    args: IndexSlice,
};

const Arg = union(enum) {
    immediate: u32,
    var_or_label: []const u8,
    ptr_deref: PtrDeref,
    string: []const u8,
};

const InitSegment = struct {
    label: []const u8,
    bytes: []const u8,
};

const PtrDeref = struct {
    var_name: []const u8,
    offset: u16,
    deref_type: VarType,
};
