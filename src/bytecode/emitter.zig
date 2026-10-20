//! AST-to-bytecode emission for the initial control-flow and call subset.

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

/// Lowers the arithmetic, branch, and bare-call subset. Unsupported syntax is
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

    fn emitStatement(self: *BytecodeEmitter, statement: *const zstatements.Statement) anyerror!void {
        switch (statement.data) {
            .block => |items| for (items) |item| try self.emitStatement(item),
            .return_stmt => |value| {
                if (value) |expression| {
                    const register = try self.emitExpression(expression);
                    try self.emitOp(.{ .opcode = .return_value, .a = register });
                } else try self.emitOp(.{ .opcode = .return_undefined });
            },
            .expr_stmt => |expression| _ = try self.emitExpression(expression),
            .variable => |variable| try self.emitVariable(variable),
            .if_stmt => |item| try self.emitIf(item),
            .while_stmt => |item| try self.emitWhile(item),
            .for_stmt => |item| try self.emitFor(item.head, item.body),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitVariable(self: *BytecodeEmitter, variable: anytype) !void {
        for (variable.declarators) |declarator| {
            if (declarator.pattern.* != .identifier or declarator.init == null) return error.UnsupportedSyntax;
            const slot = self.scope.localSlot(declarator.pattern.identifier.name) orelse return error.UnknownLocal;
            const value = try self.emitExpression(declarator.init.?);
            try self.emitOp(.{ .opcode = .store_local, .a = try small(slot), .b = value });
        }
    }

    fn emitIf(self: *BytecodeEmitter, item: anytype) anyerror!void {
        const condition = try self.emitExpression(item.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        try self.emitStatement(item.consequent);
        if (item.alternate) |alternate| {
            const end_jump = try self.emitJump(.jump, 0);
            try self.patchJump(false_jump, self.ops.items.len);
            try self.emitStatement(alternate);
            try self.patchJump(end_jump, self.ops.items.len);
        } else try self.patchJump(false_jump, self.ops.items.len);
    }

    fn emitWhile(self: *BytecodeEmitter, item: anytype) anyerror!void {
        const start = self.ops.items.len;
        const condition = try self.emitExpression(item.test_expr);
        const end_jump = try self.emitJump(.jump_if_false, condition);
        try self.emitStatement(item.body);
        const back = try self.emitJump(.jump, 0);
        try self.patchJump(back, start);
        try self.patchJump(end_jump, self.ops.items.len);
    }

    fn emitFor(self: *BytecodeEmitter, head: zstatements.ForHead, body: *const zstatements.Statement) anyerror!void {
        const c_style = switch (head) {
            .c_style => |item| item,
            else => return error.UnsupportedSyntax,
        };
        if (c_style.init) |init| switch (init) {
            .decl => |variable| try self.emitVariable(variable),
            .expr => |expression| _ = try self.emitExpression(expression),
        };
        const start = self.ops.items.len;
        var end_jump: ?usize = null;
        if (c_style.test_expr) |test_expr| {
            const condition = try self.emitExpression(test_expr);
            end_jump = try self.emitJump(.jump_if_false, condition);
        }
        try self.emitStatement(body);
        if (c_style.update) |update| _ = try self.emitExpression(update);
        const back = try self.emitJump(.jump, 0);
        try self.patchJump(back, start);
        if (end_jump) |jump| try self.patchJump(jump, self.ops.items.len);
    }

    fn emitExpression(self: *BytecodeEmitter, expression: *const zparser.Node) anyerror!u8 {
        switch (expression.data) {
            .number_literal => |number| return self.emitConstant(.{ .number = number }),
            .string_literal => |string| return self.emitConstant(.{ .string = string }),
            .boolean_literal => |boolean| return self.emitConstant(.{ .boolean = boolean }),
            .null_literal => return self.emitSimple(.load_null),
            .identifier => |name| return self.emitIdentifier(name),
            .paren => |inner| return self.emitExpression(inner),
            .binary => |binary| return self.emitBinary(binary),
            .assignment => |assignment| {
                if (assignment.op != .assign or assignment.target.data != .identifier) return error.UnsupportedSyntax;
                const slot = self.scope.localSlot(assignment.target.data.identifier) orelse return error.UnknownLocal;
                const value = try self.emitExpression(assignment.value);
                try self.emitOp(.{ .opcode = .store_local, .a = try small(slot), .b = value });
                return value;
            },
            .conditional => |conditional| return self.emitConditional(conditional),
            .call => |call| return self.emitCall(call),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitIdentifier(self: *BytecodeEmitter, name: []const u8) !u8 {
        const destination = try self.allocRegister();
        if (self.scope.localSlot(name)) |slot| {
            try self.emitOp(.{ .opcode = .load_local, .a = destination, .b = try small(slot) });
        } else {
            const constant = try self.addConstant(.{ .property_key = name });
            try self.emitOp(.{ .opcode = .load_global, .a = destination, .b = constant });
        }
        return destination;
    }

    fn emitBinary(self: *BytecodeEmitter, binary: anytype) anyerror!u8 {
        const opcode: codeblock.Opcode = switch (binary.op) {
            .add => .add,
            .sub => .sub_num,
            .mul => .mul_num,
            .div => .div_num,
            .mod => .mod_num,
            .lt => .lt_num,
            .gt => .gt_num,
            .le => .le_num,
            .ge => .ge_num,
            .eq, .eqeqeq => .eq,
            .ne, .noteqeq => .ne,
            else => return error.UnsupportedSyntax,
        };
        const left = try self.emitExpression(binary.left);
        const right = try self.emitExpression(binary.right);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = opcode, .a = destination, .b = left, .c = right });
        return destination;
    }

    fn emitConditional(self: *BytecodeEmitter, conditional: anytype) anyerror!u8 {
        const destination = try self.allocRegister();
        const condition = try self.emitExpression(conditional.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        const consequent = try self.emitExpression(conditional.consequent);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = consequent });
        const end_jump = try self.emitJump(.jump, 0);
        try self.patchJump(false_jump, self.ops.items.len);
        const alternate = try self.emitExpression(conditional.alternate);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = alternate });
        try self.patchJump(end_jump, self.ops.items.len);
        return destination;
    }

    fn emitCall(self: *BytecodeEmitter, call: anytype) anyerror!u8 {
        if (call.optional) return error.UnsupportedSyntax;
        const callee = try self.emitExpression(call.callee);
        if (self.next_register != @as(u16, callee) + 1) return error.UnsupportedSyntax;
        const argument_slots: u16 = std.math.cast(u16, call.args.len) orelse return error.TooManyRegisters;
        const arg_count = try small(argument_slots);
        const arg_base = self.next_register;
        self.next_register += argument_slots;
        self.max_register = @max(self.max_register, self.next_register);
        for (call.args, 0..) |argument, index| {
            if (argument.data == .spread) return error.UnsupportedSyntax;
            const value = try self.emitExpression(argument);
            try self.emitOp(.{ .opcode = .move, .a = try small(arg_base + @as(u16, @intCast(index))), .b = value });
        }
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = .call, .a = destination, .b = callee, .c = arg_count });
        return destination;
    }

    fn emitSimple(self: *BytecodeEmitter, opcode: codeblock.Opcode) !u8 {
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = opcode, .a = destination });
        return destination;
    }

    fn emitConstant(self: *BytecodeEmitter, constant: codeblock.Constant) !u8 {
        const index = try self.addConstant(constant);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = .load_const, .a = destination, .b = index });
        return destination;
    }

    fn addConstant(self: *BytecodeEmitter, constant: codeblock.Constant) !u8 {
        if (self.constants.items.len > std.math.maxInt(u8)) return error.TooManyConstants;
        const index: u8 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, constant);
        return index;
    }

    fn emitJump(self: *BytecodeEmitter, opcode: codeblock.Opcode, condition: u8) !usize {
        try self.emitOp(.{ .opcode = opcode, .a = condition });
        return self.ops.items.len - 1;
    }

    fn patchJump(self: *BytecodeEmitter, instruction: usize, target: usize) !void {
        if (target > std.math.maxInt(u16)) return error.TooManyInstructions;
        self.ops.items[instruction].b = @intCast(target >> 8);
        self.ops.items[instruction].c = @intCast(target);
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
            .load_local, .load_global => try output.print(allocator, " r{d}, @{d}", .{ op.a, op.b }),
            .store_local => try output.print(allocator, " @{d}, r{d}", .{ op.a, op.b }),
            .add, .sub_num, .mul_num, .div_num, .mod_num, .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .jump => try output.print(allocator, " {d}", .{jumpTarget(op)}),
            .jump_if_true, .jump_if_false => try output.print(allocator, " r{d}, {d}", .{ op.a, jumpTarget(op) }),
            .call => try output.print(allocator, " r{d}, r{d}, {d}", .{ op.a, op.b, op.c }),
            .return_value => try output.print(allocator, " r{d}", .{op.a}),
            else => {},
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

pub fn jumpTarget(op: codeblock.Op) usize {
    return (@as(usize, op.b) << 8) | op.c;
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
