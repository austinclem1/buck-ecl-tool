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
state: State,
blocks: std.StringArrayHashMap(IndexSlice),
commands: std.ArrayList(Ast.Command),
args: std.ArrayList(Arg),
vars: std.StringArrayHashMap(VarInfo),
init_segments: std.StringArrayHashMap([]const u8),

pub fn init(allocator: Allocator) TextParser {
    return .{
        .allocator = allocator,
        .state = .start,
        .blocks = std.StringArrayHashMap(IndexSlice).init(allocator),
        .commands = std.ArrayList(Ast.Command).init(allocator),
        .args = std.ArrayList(Arg).init(allocator),
        .vars = std.StringArrayHashMap(VarInfo).init(allocator),
        .init_segments = std.StringArrayHashMap([]const u8).init(allocator),
    };
}

pub fn deinit(self: *TextParser) void {
    self.blocks.deinit();
    self.commands.deinit();
    self.args.deinit();
    self.vars.deinit();
    self.init_segments.deinit();

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
    var ast_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer ast_arena.deinit();

    var token_stream = try tokenize.tokenize(self.allocator, text);
    defer token_stream.free(self.allocator);

    var header_strings: ?[5][]const u8 = null;
    var in_progress_label: ?[]const u8 = null;
    var block_commands_start: usize = 0;

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
                        if (self.blocks.contains(label_str)) {
                            std.debug.print("error: Redeclaration of label {s} at byte {d}\n", .{ label_str, tok.location });
                            return error.ParsingFailed;
                        }
                        if (self.init_segments.contains(label_str)) {
                            std.debug.print("error: Redeclaration of label {s} at byte {d}\n", .{ label_str, tok.location });
                            return error.ParsingFailed;
                        }
                        in_progress_label = label_str;
                        self.state = .parsing_new_block;
                    },
                    .newline => _ = token_stream.next(),
                    .eof => {
                        self.state = .done;
                    },
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
                    .command => {
                        block_commands_start = self.commands.items.len;
                        self.state = .parsing_command_block;
                    },
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
                    .identifier, .eof => {
                        try self.blocks.putNoClobber(in_progress_label.?, IndexSlice{
                            .start = block_commands_start,
                            .stop = self.commands.items.len,
                        });
                        in_progress_label = null;
                        self.state = switch (tok.variant) {
                            .identifier => .start,
                            .eof => .done,
                            else => unreachable,
                        };
                    },
                    else => {
                        std.debug.print("error: Expected command, found {s} at byte {d}\n", .{ @tagName(tok.variant), tok.location });
                        return error.ParsingFailed;
                    },
                }
            },
            .parsing_bytes_block => {
                const tok = token_stream.peek();
                switch (tok.variant) {
                    .newline => _ = token_stream.next(),
                    .keyword_BYTES => {
                        const duped_bytes = try parseBytes(ast_arena.allocator(), &token_stream);
                        try self.init_segments.putNoClobber(in_progress_label.?, duped_bytes);
                        in_progress_label = null;
                    },
                    .identifier => self.state = .start,
                    .eof => self.state = .done,
                    else => {
                        std.debug.print("error: Expected \"BYTES\", found {s} at byte {d}\n", .{ @tagName(tok.variant), tok.location });
                        return error.ParsingFailed;
                    },
                }
            },
            else => @panic("TODO"),
        }
    }

    {
        const SortByAddress = struct {
            vals: []const VarInfo,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.vals[a_index].address < ctx.vals[b_index].address;
            }
        };
        self.vars.sort(SortByAddress{ .vals = self.vars.values() });
    }

    var ast_header: [5]usize = undefined;
    if (header_strings) |strings| {
        for (strings, 0..) |str, i| {
            ast_header[i] = self.blocks.getIndex(str) orelse {
                std.debug.print("error: no definition found for header label \"{s}\"\n", .{str});
                return error.ParsingFailed;
            };
        }
    } else {
        std.debug.print("error: header never defined\n", .{});
        return error.ParsingFailed;
    }

    const ast_blocks = try ast_arena.allocator().alloc(Ast.Block, self.blocks.count());
    for (ast_blocks, 0..) |*dest, i| {
        const duped_label = try ast_arena.allocator().dupe(u8, self.blocks.keys()[i]);
        dest.* = Ast.Block{
            .label = duped_label,
            .commands = self.blocks.values()[i],
        };
    }

    const ast_commands = try ast_arena.allocator().dupe(Ast.Command, self.commands.items);

    const ast_args = try ast_arena.allocator().alloc(Ast.Arg, self.args.items.len);
    for (ast_args, 0..) |*dest, i| {
        dest.* = switch (self.args.items[i]) {
            .immediate => |val| Ast.Arg{ .immediate = val },
            .var_or_label => |str| blk: {
                if (self.vars.getIndex(str)) |var_index| {
                    break :blk Ast.Arg{ .var_use = var_index };
                }
                if (self.blocks.getIndex(str)) |block_index| {
                    break :blk Ast.Arg{ .jump_dest_block = block_index };
                }
                if (self.init_segments.getIndex(str)) |segment_index| {
                    break :blk Ast.Arg{ .init_data_segment = segment_index };
                }
                std.debug.print("error: identifier \"{s}\" not associated with a variable, label, or bytes segment\n", .{str});
                return error.ParsingFailed;
            },
            .ptr_deref => |deref_info| blk: {
                const var_index = self.vars.getIndex(deref_info.var_name) orelse {
                    std.debug.print("error: variable \"{s}\" never declared\n", .{deref_info.var_name});
                    return error.ParsingFailed;
                };
                const offset = std.math.cast(u16, deref_info.offset) orelse {
                    std.debug.print("error: offset of {d} for pointer deref of \"{s}\" too large (must fit in u16)\n", .{ deref_info.offset, deref_info.var_name });
                    return error.ParsingFailed;
                };
                break :blk Ast.Arg{ .ptr_deref = .{
                    .ptr_var_id = var_index,
                    .offset = offset,
                    .deref_type = deref_info.deref_type,
                } };
            },
            .string => |str| blk: {
                const duped = try ast_arena.allocator().dupe(u8, str);
                break :blk Ast.Arg{ .string = duped };
            },
        };
    }

    const ast_init_segments = try ast_arena.allocator().alloc(Ast.InitSegment, self.init_segments.count());
    for (ast_init_segments, 0..) |*dest, i| {
        const duped_name = try ast_arena.allocator().dupe(u8, self.init_segments.keys()[i]);
        const duped_bytes = try ast_arena.allocator().dupe(u8, self.init_segments.values()[i]);
        dest.* = Ast.InitSegment{
            .name = duped_name,
            .bytes = duped_bytes,
        };
    }

    const ast_vars = try ast_arena.allocator().alloc(Ast.Var, self.vars.count());
    for (ast_vars, 0..) |*dest, i| {
        const duped_name = try ast_arena.allocator().dupe(u8, self.vars.keys()[i]);
        dest.* = Ast.Var{
            .name = duped_name,
            .address = self.vars.values()[i].address,
            .var_type = self.vars.values()[i].var_type,
        };
    }

    return Ast{
        .header = ast_header,
        .blocks = ast_blocks,
        .commands = ast_commands,
        .args = ast_args,
        .init_segments = ast_init_segments,
        .vars = ast_vars,
        .arena = ast_arena,
    };
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
            if (token_stream.peekN(1).variant == .lsquare_bracket) {
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

fn parseBytes(allocator: Allocator, token_stream: *TokenStream) (ParseError || error{OutOfMemory})![]const u8 {
    const keyword_tok = try expect(token_stream, .keyword_BYTES);

    var bytes_count: usize = 0;
    while (token_stream.peekN(bytes_count).variant == .number) : (bytes_count += 1) {}

    if (bytes_count == 0) {
        std.debug.print("error: expected number literal after \"BYTES\" at {d}\n", .{keyword_tok.location});
        return error.ParsingFailed;
    }

    const result = try allocator.alloc(u8, bytes_count);
    for (result) |*dest| {
        const num_tok = token_stream.next();
        const val = std.math.cast(u8, num_tok.variant.number) orelse {
            std.debug.print("error: BYTES arg {d} at {d} must fit within a u8\n", .{ num_tok.variant.number, num_tok.location });
            return error.ParsingFailed;
        };
        dest.* = val;
    }

    const end_tok = token_stream.next();
    switch (end_tok.variant) {
        .newline, .eof => {},
        else => {
            std.debug.print("error: expected newline or EOF at {d} after BYTES line\n", .{end_tok.location});
            return error.ParsingFailed;
        },
    }

    return result;
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
