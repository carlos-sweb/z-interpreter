//! AST-to-bytecode emission for the first non-executing VM milestone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zfunctions = @import("zfunctions");
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const codeblock = @import("codeblock.zig");

pub const CompiledCodeBlock = struct {
    block: codeblock.CodeBlock,

    pub fn deinit(self: *CompiledCodeBlock, allocator: Allocator) void {
        allocator.free(self.block.ops);
        allocator.free(self.block.constants);
        allocator.free(self.block.exception_table);
        self.* = undefined;
    }
};

/// Lowers the deliberately small arithmetic subset. Unsupported syntax is
/// reported during compilation; it still executes through the AST walker.
pub const BytecodeEmitter = struct {
    allocator: Allocator,
    scope: codeblock.ScopeAnalysis,
    ops: std.ArrayListUnmanaged(codeblock.Op) = .empty,
    constants: std.ArrayListUnmanaged(codeblock.Constant) = .empty,
    next_register: u16,
    max_register: u16,

    pub fn emit(allocator: Allocator, function: *const zfunctions.FunctionNode) !CompiledCodeBlock {
        const scope = try codeblock.ScopeAnalyzer.analyze(allocator, function);
        var self = BytecodeEmitter{
            .allocator = allocator,
            .scope = scope,
            .next_register = scope.local_count,
            .max_register = scope.local_count,
        };
        defer self.scope.deinit(allocator);
        errdefer self.ops.deinit(allocator);
        errdefer self.constants.deinit(allocator);

        try self.emitBody(function.body);
        const ops = try self.ops.toOwnedSlice(allocator);
        errdefer allocator.free(ops);
        const constants = try self.constants.toOwnedSlice(allocator);
        errdefer allocator.free(constants);
        return .{ .block = .{
            .ops = ops,
            .constants = constants,
            .local_count = scope.local_count,
            .register_count = self.max_register,
            .param_count = scope.param_count,
            .capture_count = @intCast(scope.captured_locals.len),
            .flags = scope.flags,
            .name = functionName(function),
        } };
    }

    fn functionName(function: *const zfunctions.FunctionNode) ?[]const u8 {
        return switch (function.kind) {
            .function_decl => |kind| kind.name,
            .function_expr => |kind| kind.name,
            .method => |kind| kind.name,
            .arrow => null,
        };
    }

    fn emitBody(self: *BytecodeEmitter, body: zfunctions.FunctionBody) !void {
        switch (body) {
            .expression => |expression| {
                const value = try self.emitExpression(expression);
                try self.emitOp(.{ .opcode = .return_value, .a = value });
            },
            .block => |block| {
                for (block.data.block) |statement| try self.emitStatement(statement);
                if (self.ops.items.len == 0 or self.ops.items[self.ops.items.len - 1].opcode != .return_value)
                    try self.emitOp(.{ .opcode = .return_undefined });
            },
        }
    }

    fn emitStatement(self: *BytecodeEmitter, statement: *const zstatements.Statement) !void {
        switch (statement.data) {
            .return_stmt => |value| {
                if (value) |expression| {
                    const register = try self.emitExpression(expression);
                    try self.emitOp(.{ .opcode = .return_value, .a = register });
                } else try self.emitOp(.{ .opcode = .return_undefined });
            },
            .expr_stmt => |expression| _ = try self.emitExpression(expression),
            .variable => |variable| for (variable.declarators) |declarator| {
                if (declarator.pattern.* != .identifier or declarator.init == null) return error.UnsupportedSyntax;
                const slot = self.scope.localSlot(declarator.pattern.identifier.name) orelse return error.UnknownLocal;
                const value = try self.emitExpression(declarator.init.?);
                try self.emitOp(.{ .opcode = .store_local, .a = try small(slot), .b = value });
            },
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitExpression(self: *BytecodeEmitter, expression: *const zparser.Node) !u8 {
        switch (expression.data) {
            .number_literal => |number| return self.emitConstant(.{ .number = number }),
            .string_literal => |string| return self.emitConstant(.{ .string = string }),
            .boolean_literal => |boolean| return self.emitConstant(.{ .boolean = boolean }),
            .identifier => |name| {
                const slot = self.scope.localSlot(name) orelse return error.UnknownLocal;
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .load_local, .a = destination, .b = try small(slot) });
                return destination;
            },
            .paren => |inner| return self.emitExpression(inner),
            .binary => |binary| {
                const opcode: codeblock.Opcode = switch (binary.op) {
                    .add => .add,
                    .sub => .sub_num,
                    .mul => .mul_num,
                    .div => .div_num,
                    else => return error.UnsupportedSyntax,
                };
                const left = try self.emitExpression(binary.left);
                const right = try self.emitExpression(binary.right);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = opcode, .a = destination, .b = left, .c = right });
                return destination;
            },
            .assignment => |assignment| {
                if (assignment.op != .assign or assignment.target.data != .identifier) return error.UnsupportedSyntax;
                const slot = self.scope.localSlot(assignment.target.data.identifier) orelse return error.UnknownLocal;
                const value = try self.emitExpression(assignment.value);
                try self.emitOp(.{ .opcode = .store_local, .a = try small(slot), .b = value });
                return value;
            },
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitConstant(self: *BytecodeEmitter, constant: codeblock.Constant) !u8 {
        if (self.constants.items.len > std.math.maxInt(u8)) return error.TooManyConstants;
        const index: u8 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, constant);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = .load_const, .a = destination, .b = index });
        return destination;
    }

    fn allocRegister(self: *BytecodeEmitter) !u8 {
        const register = try small(self.next_register);
        self.next_register += 1;
        self.max_register = @max(self.max_register, self.next_register);
        return register;
    }

    fn emitOp(self: *BytecodeEmitter, op: codeblock.Op) !void {
        try self.ops.append(self.allocator, op);
    }
};

fn small(value: u16) !u8 {
    if (value > std.math.maxInt(u8)) return error.TooManyRegisters;
    return @intCast(value);
}

pub fn disassemble(allocator: Allocator, block: *const codeblock.CodeBlock) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    for (block.ops, 0..) |op, index| {
        try output.print(allocator, "{d:0>4} {s}", .{ index, @tagName(op.opcode) });
        switch (op.opcode) {
            .load_const => try output.print(allocator, " r{d}, #{d}", .{ op.a, op.b }),
            .load_local => try output.print(allocator, " r{d}, @{d}", .{ op.a, op.b }),
            .store_local => try output.print(allocator, " @{d}, r{d}", .{ op.a, op.b }),
            .add, .sub_num, .mul_num, .div_num => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .return_value => try output.print(allocator, " r{d}", .{op.a}),
            else => {},
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

test "emitter disassembles an add function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function add(a, b) { return a + b; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var compiled = try BytecodeEmitter.emit(std.testing.allocator, function);
    defer compiled.deinit(std.testing.allocator);
    const text = try disassemble(std.testing.allocator, &compiled.block);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "0000 load_local r2, @0\n" ++
            "0001 load_local r3, @1\n" ++
            "0002 add r4, r2, r3\n" ++
            "0003 return_value r4\n",
        text,
    );
}
