const TextParser = @This();

const std = @import("std");

const tokenize = @import("tokenize.zig");
const TokenStream = tokenize.TokenStream;
const Token = tokenize.Token;

const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

const VarType = @import("VarType.zig").VarType;
const IndexSlice = @import("../IndexSlice.zig");

allocator: Allocator,
ast_arena: std.heap.ArenaAllocator,
state: State,
state_stack: std.BoundedArray(State, 16),
labels_set: std.StringArrayHashMap(void), // index of each label is associated block index
blocks: std.ArrayList(Ast.Block),
commands: std.ArrayList(Ast.Command),
args: std.ArrayList(Arg),
vars: std.StringArrayHashMap(VarInfo),

pub fn init(allocator: Allocator) TextParser {
    return .{
        .allocator = allocator,
        .ast_arena = std.heap.ArenaAllocator.init(allocator),
        .state = .start,
        .state_stack = std.BoundedArray(State, 16).init(0) catch unreachable,
        .labels_set = std.StringArrayHashMap(void).init(allocator),
        .blocks = std.ArrayList(Ast.Block).init(allocator),
        .commands = std.ArrayList(Ast.Command).init(allocator),
        .args = std.ArrayList(Arg).init(allocator),
        .vars = std.StringArrayHashMap(VarInfo).init(allocator),
    };
}

pub fn deinit(self: *TextParser) void {
    // self.ast_arena intentionally not freed here, the resulting AST owns it
    self.labels_set.deinit();
    self.blocks.deinit();
    self.commands.deinit();
    self.args.deinit();
    self.vars.deinit();

    self.* = undefined;
}

const State = enum {
    start,
    parsing_new_block,
    parsing_command_block,
    parsing_bytes_block,
    done,
    failed,
};

pub fn parse(self: *TextParser, text: []const u8) !Ast {
    var token_stream = try tokenize.tokenize(self.allocator, text);
    defer token_stream.free(self.allocator);

    var header_strings: ?[5][]const u8 = null;

    while (true) {
        switch (self.state) {
            .done => break,
            .start => {
                const tok = token_stream.peek();
                switch (tok.variant) {
                    .keyword_header => {
                        if (header_strings != null) {
                            std.debug.print("error: Redeclaration of header at byte {d}\n", .{tok.location});
                        }
                        header_strings = try parseHeader(&token_stream);
                    },
                    .keyword_var => {
                        const new_var = try parseVar(&token_stream);
                        const gop = try self.vars.getOrPut(new_var.name);
                        if (gop.found_existing) {
                            std.debug.print("error: Redeclaration of var {s} at byte {d}\n", .{ new_var.name, tok.location });
                            return error.ParsingFailed;
                        } else {
                            gop.value_ptr.* = .{ .address = new_var.address, .var_type = new_var.var_type };
                        }
                    },
                    .identifier => {
                        const label_str = try parseLabel(&token_stream);
                        if (self.labels_set.contains(label_str)) {
                            std.debug.print("error: Redeclaration of label {s} at byte {d}\n", .{ label_str, tok.location });
                            return error.ParsingFailed;
                        }
                        const duped_label_str = try self.ast_arena.allocator().dupe(u8, label_str);
                        try self.labels_set.putNoClobber(duped_label_str, {});
                        self.state = .parsing_new_block;
                    },
                    .newline => _ = token_stream.next(),
                    else => {
                        std.debug.print("error: Expected header or label definition, found {s} at byte {d}\n", .{ @tagName(tok.variant), tok.location });
                        return error.ParsingFailed;
                    },
                }
            },
            .parsing_new_block => {
                const tok = token_stream.peek();
                switch (tok.variant) {
                    .newline => _ = token_stream.next(),
                    .command => self.state = .parsing_command_block,
                    .keyword_BYTES => self.state = .parsing_bytes_block,
                    else => {
                        std.debug.print("error: Expected command or \"BYTES\", found {s} at byte {d}\n", .{ @tagName(tok.variant), tok.location });
                        return error.ParsingFailed;
                    },
                }
            },
            .parsing_command_block => {
                const tok = token_stream.peek();
                switch (tok.variant) {
                    .newline => _ = token_stream.next(),
                    .command => try self.parseCommand(&token_stream),
                    .keyword_BYTES => self.state = .parsing_bytes_block,
                    .identifier => self.state = .start,
                    .eof => self.state = .done,
                    else => {
                        std.debug.print("error: Expected command or \"BYTES\", found {s} at byte {d}\n", .{ @tagName(tok.variant), tok.location });
                        return error.ParsingFailed;
                    },
                }
            },
            else => @panic("TODO"),
        }
        // switch (tok) {
        //     .identifier => |str| std.debug.print("identifier: {s}\n", .{str}),
        //     .string => |str| std.debug.print("string: \"{s}\"\n", .{str}),
        //     else => std.debug.print("{any}\n", .{tok}),
        // }
    }

    return undefined;
}

const ParseError = error{
    ParsingFailed,
};

fn expect(token_stream: *TokenStream, expected: std.meta.Tag(Token.Variant)) ParseError!Token {
    const tok = token_stream.next();
    if (std.meta.activeTag(tok.variant) != expected) {
        std.debug.print("error: Expected {s} at byte {d}, found {s}\n", .{ Token.toString(expected), tok.location, Token.toString(tok.variant) });
        return error.ParsingFailed;
    }
    return tok;
}

fn parseHeader(token_stream: *TokenStream) ParseError![5][]const u8 {
    var header_strings = [1][]const u8{""} ** 5;

    std.debug.assert(token_stream.peek().variant == .keyword_header);
    _ = token_stream.next();
    _ = try expect(token_stream, .colon);

    for (&header_strings) |*h_str| {
        token_stream.eatAny(.newline);
        const tok = try expect(token_stream, .identifier);
        h_str.* = tok.variant.identifier;
    }

    return header_strings;
}

fn parseLabel(token_stream: *TokenStream) ParseError![]const u8 {
    const tok = token_stream.next();
    _ = try expect(token_stream, .colon);

    return tok.variant.identifier;
}

fn parseVar(token_stream: *TokenStream) ParseError!Ast.Var {
    _ = try expect(token_stream, .keyword_var);
    const identifier = try expect(token_stream, .identifier);
    _ = try expect(token_stream, .colon);
    const var_type = blk: {
        const tok = token_stream.next();
        break :blk switch (tok.variant) {
            .keyword_byte => VarType.byte,
            .keyword_word => VarType.word,
            .keyword_dword => VarType.dword,
            .keyword_pointer => VarType.pointer,
            else => {
                std.debug.print("error: Expected var type at byte {d}\n", .{tok.location});
                return error.ParsingFailed;
            },
        };
    };
    _ = try expect(token_stream, .at_sign);
    const address: u16 = blk: {
        const num = try expect(token_stream, .number);
        break :blk std.math.cast(u16, num.variant.number) orelse {
            std.debug.print("error: Var address at byte {d} doesn't fit into u16\n", .{num.location});
            return error.ParsingFailed;
        };
    };

    return Ast.Var{
        .name = identifier.variant.identifier,
        .address = address,
        .var_type = var_type,
    };
}

fn parseCommand(self: *TextParser, token_stream: *TokenStream) (ParseError || error{OutOfMemory})!void {
    const cmd_tag_tok = try expect(token_stream, .command);

    const args_start = self.args.items.len;
    while (try maybeParseCommandArg(token_stream)) |arg| {
        try self.args.append(arg);
    }
    const args_stop = self.args.items.len;
    try self.commands.append(Ast.Command{
        .args = .{ .start = args_start, .stop = args_stop },
        .tag = cmd_tag_tok.variant.command,
    });
}

fn parsePtrDeref(token_stream: *TokenStream) ParseError!Arg {
    const var_identifier = try expect(token_stream, .identifier);
    _ = try expect(token_stream, .lsquare_bracket);
    const num = try expect(token_stream, .number);
    _ = try expect(token_stream, .rsquare_bracket);
    const deref_type = blk: {
        const tok = token_stream.next();
        break :blk switch (tok.variant) {
            .keyword_b => VarType.byte,
            .keyword_w => VarType.word,
            .keyword_d => VarType.dword,
            else => {
                std.debug.print("error: Expected 'b', 'w', or 'd' at byte {d} folowing closing square bracket\n", .{tok.location});
                return error.ParsingFailed;
            },
        };
    };

    return Arg{ .ptr_deref = PtrDeref{
        .var_name = var_identifier.variant.identifier,
        .offset = num.variant.number,
        .deref_type = deref_type,
    } };
}

fn maybeParseCommandArg(token_stream: *TokenStream) ParseError!?Arg {
    const tok = token_stream.peek();
    switch (tok.variant) {
        .newline, .eof => return null,
        .number => {
            const num = token_stream.next();
            return Arg{ .immediate = num.variant.number };
        },
        .string => {
            const str = token_stream.next();
            return Arg{ .string = str.variant.string };
        },
        .identifier => {
            if (token_stream.peekTwo().variant == .lsquare_bracket) {
                return try parsePtrDeref(token_stream);
            } else {
                const ident = token_stream.next();
                return Arg{ .var_or_label = ident.variant.identifier };
            }
        },
        else => {
            std.debug.print("error: found {s} at byte {d}, not a valid start to a command argument\n", .{ @tagName(tok.variant), tok.location });
            return error.ParsingFailed;
        },
    }
}

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
    offset: u32,
    deref_type: VarType,
};

const VarInfo = struct {
    address: u16,
    var_type: VarType,
};
