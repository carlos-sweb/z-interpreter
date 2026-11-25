//! Phase 2 foundations. This module has no execution path yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zfunctions = @import("zfunctions");
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const Opcode = enum(u8) {
    nop,
    load_const,
    move,
    load_local,
    store_local,
    load_capture,
    store_capture,
    load_global,
    store_global,
    load_this,
    load_undefined,
    load_null,
    load_true,
    load_false,
    add_num,
    sub_num,
    mul_num,
    div_num,
    mod_num,
    lt_num,
    gt_num,
    le_num,
    ge_num,
    eq,
    ne,
    add,
    neg,
    not,
    jump,
    jump_if_true,
    jump_if_false,
    call,
    call_global,
    call_method,
    new_value,
    get_prop,
    set_prop,
    set_prop_transition,
    make_closure,
    return_value,
    return_undefined,
    throw_value,
    new_object,
    new_array,
    get_elem,
    set_elem,
    iter_init,
    iter_next,
    iter_end,
    setup_catch,
    end_catch,
    add_local_const,
    sub_local_const,
    lt_local_const,
    gt_local_const,
    le_local_const,
    ge_local_const,
    eq_local_const,
    get_elem_const,
    set_elem_const,
    jump_if_not_nullish,
    and_bits,
    or_bits,
    xor_bits,
    not_bits,
    shl,
    shr,
    ushr,
    typeof,
    pow_num,
    jeq_local_const_false,
    jlt_local_const_false,
    jle_local_const_false,
    jgt_local_const_false,
    jge_local_const_false,
    loose_eq,
    loose_ne,
    typeof_global,
    to_prop_key,
};

pub const Op = packed struct(u32) {
    opcode: Opcode,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
};

pub const Constant = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    bigint: []const u8,
    property_key: []const u8,
    function_node: *zfunctions.FunctionNode,
};

pub const Flags = packed struct(u16) {
    is_arrow: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    needs_arguments: bool = false,
    lexical_this: bool = false,
    has_try: bool = false,
    is_strict: bool = false,
    has_super: bool = false,
    has_nested_fn: bool = false,
    _reserved: u7 = 0,
};

pub const ExceptionHandler = struct {
    start_pc: u32,
    end_pc: u32,
    target_pc: u32,
    kind: enum { @"catch", finally, catch_finally },
    catch_local: ?u16 = null,
};

pub const CallSiteCache = struct {
    arg_count: u8 = 0,
    this_reg: ?u8 = null,
    callee: ?JSValue = null,
    target_block: ?*const CodeBlock = null,
    closure_env: ?*anyopaque = null,
    interp: ?*anyopaque = null,
    global_name: ?[]const u8 = null,
    global_version: u64 = 0,
};

pub const JitGlobalSlot = extern struct {
    env: ?*anyopaque = null,
    value_ptr: ?*JSValue = null,
    struct_version: u64 = 0,
    is_mutable: u64 = 0,
};

pub const OsrContext = extern struct {
    allocator_ptr: *const anyopaque,
    frame_ptr: *anyopaque,
    prop_ic_ptr: *anyopaque,
    regs_limit: [*]JSValue,
    global_version_ptr: *const u64,
    global_obj_box_ptr: usize = 0,
};

pub const OsrPropIC = extern struct {
    shape_id: u32 = 0,
    slot_idx: u32 = 0,
    slot_byte_off: u64 = 0,
    next_shape: u32 = 0,
    cached_shape_id: u32 = 0,
};

pub const JitFn = *const fn (regs: [*]JSValue, out: *JSValue, regs_limit: [*]JSValue, env: ?*anyopaque) callconv(.c) u8;
pub const OsrFn = *const fn (regs: [*]JSValue, ctx: *OsrContext) callconv(.c) u32;

pub const MAX_OSR_LOOPS: usize = 12;

pub const OsrEntry = struct {
    header_ip: u32 = std.math.maxInt(u32),
    end_ip: u32 = 0,
    count: u32 = 0,
    failed: bool = false,
    code: ?[]align(std.heap.page_size_min) u8 = null,
    fn_ptr: ?OsrFn = null,
    prop_ics: ?[]OsrPropIC = null,
};

/// Immutable representation emitted by a later compiler pass.
pub const CodeBlock = struct {
    ops: []const Op = &.{},
    constants: []const Constant = &.{},
    exception_table: []const ExceptionHandler = &.{},
    call_target_cache: []CallSiteCache = &.{},
    captured_names: []const []const u8 = &.{},
    captured_is_lexical: []const bool = &.{},
    local_count: u16 = 0,
    register_count: u16 = 0,
    param_count: u16 = 0,
    capture_count: u16 = 0,
    flags: Flags = .{},
    name: ?[]const u8 = null,
    call_count: u32 = 0,
    jit_failed: bool = false,
    jit_pure_leaf: bool = false,
    jit_string_param_mask: u32 = 0,
    jit_interp: ?*anyopaque = null,
    jit_code: ?[]align(std.heap.page_size_min) u8 = null,
    jit_fn: ?JitFn = null,
    jit_global_slots: ?[]JitGlobalSlot = null,
    osr_entries: [MAX_OSR_LOOPS]OsrEntry = @splat(.{}),

    pub fn deinitJit(self: *CodeBlock, allocator: Allocator) void {
        if (self.jit_code) |jc| {
            @import("../jit/x64_asm.zig").freeExecutable(jc);
            self.jit_code = null;
            self.jit_fn = null;
        }
        for (&self.osr_entries) |*entry| {
            if (entry.code) |oc| {
                @import("../jit/x64_asm.zig").freeExecutable(oc);
                entry.code = null;
                entry.fn_ptr = null;
            }
            if (entry.prop_ics) |pics| {
                allocator.free(pics);
                entry.prop_ics = null;
            }
        }
        if (self.jit_global_slots) |slots| {
            allocator.free(slots);
            self.jit_global_slots = null;
        }
    }
};

pub const LocalKind = enum { parameter, @"var", let, @"const", function, class, catch_binding };

pub const Local = struct {
    name: []const u8,
    slot: u16,
    kind: LocalKind,
};

/// Metadata required by the future emitter. Captured locals are slots used by
/// nested closures; free names must be provided by an enclosing scope.
pub const ScopeAnalysis = struct {
    locals: []Local,
    captured_locals: []const []const u8,
    free_names: []const []const u8,
    decl_slots: std.AutoHashMapUnmanaged(*const anyopaque, u16) = .empty,
    local_count: u16,
    register_count: u16,
    param_count: u16,
    flags: Flags,

    pub fn deinit(self: *ScopeAnalysis, allocator: Allocator) void {
        allocator.free(self.locals);
        allocator.free(self.captured_locals);
        allocator.free(self.free_names);
        self.decl_slots.deinit(allocator);
        self.* = undefined;
    }

    pub fn localSlot(self: *const ScopeAnalysis, name: []const u8) ?u16 {
        for (self.locals) |local| if (std.mem.eql(u8, local.name, name)) return local.slot;
        return null;
    }

    pub fn patternSlot(self: *const ScopeAnalysis, pattern: *const zstatements.BindingPattern) ?u16 {
        return self.decl_slots.get(@ptrCast(pattern));
    }

    pub fn capturesLocal(self: *const ScopeAnalysis, name: []const u8) bool {
        for (self.captured_locals) |captured| if (std.mem.eql(u8, captured, name)) return true;
        return false;
    }

    pub fn localKind(self: *const ScopeAnalysis, name: []const u8) ?LocalKind {
        for (self.locals) |local| if (std.mem.eql(u8, local.name, name)) return local.kind;
        return null;
    }
};

pub fn hasUseStrict(statements: anytype) bool {
    for (statements) |stmt| {
        switch (stmt.data) {
            .expr_stmt => |expr| {
                if (expr.data == .string_literal) {
                    if (std.mem.eql(u8, expr.data.string_literal, "use strict")) return true;
                } else break;
            },
            else => break,
        }
    }
    return false;
}

pub fn functionHasUseStrict(function: *const zfunctions.FunctionNode) bool {
    switch (function.body) {
        .block => |block_stmt| {
            if (block_stmt.data == .block) {
                return hasUseStrict(block_stmt.data.block);
            }
        },
        .expression => {},
    }
    return false;
}

/// Conservative function-scope analysis. It allocates unique slots for every
/// parameter and declaration. Precise block-scope TDZ placement is deferred
/// to bytecode emission, while nested-function free names already identify
/// closure captures.
pub const ScopeAnalyzer = struct {
    const ActiveDecl = struct {
        name: []const u8,
        slot: u16,
        kind: LocalKind,
        depth: u16,
        in_loop: bool,
    };

    allocator: Allocator,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    active_decls: std.ArrayListUnmanaged(ActiveDecl) = .empty,
    root_vars: std.StringHashMapUnmanaged(u16) = .empty,
    decl_slots: std.AutoHashMapUnmanaged(*const anyopaque, u16) = .empty,
    captured: std.ArrayListUnmanaged([]const u8) = .empty,
    captured_names: std.StringHashMapUnmanaged(void) = .empty,
    free: std.ArrayListUnmanaged([]const u8) = .empty,
    free_names: std.StringHashMapUnmanaged(void) = .empty,
    param_count: u16 = 0,
    current_depth: u16 = 0,
    loop_depth: u16 = 0,
    has_super: bool = false,
    has_nested_fn: bool = false,

    pub fn analyze(allocator: Allocator, function: *const zfunctions.FunctionNode) anyerror!ScopeAnalysis {
        var self = ScopeAnalyzer{ .allocator = allocator };
        defer self.active_decls.deinit(allocator);
        defer self.root_vars.deinit(allocator);
        defer self.captured_names.deinit(allocator);
        defer self.free_names.deinit(allocator);
        errdefer self.decl_slots.deinit(allocator);
        errdefer self.locals.deinit(allocator);
        errdefer self.captured.deinit(allocator);
        errdefer self.free.deinit(allocator);

        for (function.params.items) |param| {
            try self.addParamPattern(param.pattern);
            if (param.default) |default| try self.scanNode(default);
        }
        self.param_count = @intCast(self.locals.items.len);
        if (function.params.rest) |rest| {
            try self.addParamPattern(rest);
            self.param_count += 1;
        }

        switch (function.body) {
            .block => |block_stmt| {
                if (block_stmt.data == .block) {
                    const stmts = block_stmt.data.block;
                    try self.predeclRootFunctions(stmts);
                    try self.precollectVarsInStatements(stmts);
                    try self.predeclDirectLexicals(stmts);
                    for (stmts) |stmt| try self.walkStatement(stmt);
                } else {
                    try self.precollectVarsInStatement(block_stmt);
                    try self.walkStatement(block_stmt);
                }
            },
            .expression => |expression| try self.scanNode(expression),
        }

        const locals = try self.locals.toOwnedSlice(allocator);
        errdefer allocator.free(locals);
        const captured = try self.captured.toOwnedSlice(allocator);
        errdefer allocator.free(captured);
        const free = try self.free.toOwnedSlice(allocator);
        errdefer allocator.free(free);
        const count: u16 = @intCast(locals.len);
        return .{
            .locals = locals,
            .captured_locals = captured,
            .free_names = free,
            .decl_slots = self.decl_slots,
            .local_count = count,
            .register_count = count,
            .param_count = self.param_count,
            .flags = .{
                .is_arrow = function.kind == .arrow,
                .is_generator = function.is_generator,
                .is_async = function.is_async,
                .lexical_this = function.kind == .arrow,
                .has_super = self.has_super,
                .has_nested_fn = self.has_nested_fn,
                .is_strict = functionHasUseStrict(function),
            },
        };
    }

    pub fn analyzeStatements(allocator: Allocator, statements: anytype) anyerror!ScopeAnalysis {
        var self = ScopeAnalyzer{ .allocator = allocator };
        defer self.active_decls.deinit(allocator);
        defer self.root_vars.deinit(allocator);
        defer self.captured_names.deinit(allocator);
        defer self.free_names.deinit(allocator);
        errdefer self.decl_slots.deinit(allocator);
        errdefer self.locals.deinit(allocator);
        errdefer self.captured.deinit(allocator);
        errdefer self.free.deinit(allocator);

        try self.predeclRootFunctions(statements);
        try self.precollectVarsInStatements(statements);
        try self.predeclDirectLexicals(statements);
        for (statements) |statement| try self.walkStatement(statement);

        const locals = try self.locals.toOwnedSlice(allocator);
        errdefer allocator.free(locals);
        const captured = try self.captured.toOwnedSlice(allocator);
        errdefer allocator.free(captured);
        const free = try self.free.toOwnedSlice(allocator);
        errdefer allocator.free(free);
        const count: u16 = @intCast(locals.len);
        return .{
            .locals = locals,
            .captured_locals = captured,
            .free_names = free,
            .decl_slots = self.decl_slots,
            .local_count = count,
            .register_count = count,
            .param_count = 0,
            .flags = .{
                .has_super = self.has_super,
                .has_nested_fn = self.has_nested_fn,
                .is_strict = hasUseStrict(statements),
            },
        };
    }

    fn allocSlot(self: *ScopeAnalyzer, name: []const u8, kind: LocalKind) !u16 {
        const slot = std.math.cast(u16, self.locals.items.len) orelse return error.TooManyRegisters;
        try self.locals.append(self.allocator, .{ .name = name, .slot = slot, .kind = kind });
        return slot;
    }

    fn hasActiveAtDepth(self: *const ScopeAnalyzer, name: []const u8, depth: u16) bool {
        var i = self.active_decls.items.len;
        while (i > 0) {
            i -= 1;
            const d = self.active_decls.items[i];
            if (d.depth < depth) break;
            if (d.depth == depth and std.mem.eql(u8, d.name, name)) return true;
        }
        return false;
    }

    fn hasLexicalAtDepth(self: *const ScopeAnalyzer, name: []const u8, depth: u16) bool {
        var i = self.active_decls.items.len;
        while (i > 0) {
            i -= 1;
            const d = self.active_decls.items[i];
            if (d.depth < depth) break;
            if (d.depth == depth and std.mem.eql(u8, d.name, name)) {
                return switch (d.kind) {
                    .let, .@"const", .class, .catch_binding => true,
                    else => false,
                };
            }
        }
        return false;
    }

    fn hasEnclosingLexical(self: *const ScopeAnalyzer, name: []const u8) bool {
        for (self.active_decls.items) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                switch (d.kind) {
                    .let, .@"const", .class, .catch_binding => return true,
                    else => {},
                }
            }
        }
        return false;
    }

    fn resolveActive(self: *const ScopeAnalyzer, name: []const u8) ?ActiveDecl {
        var i = self.active_decls.items.len;
        while (i > 0) {
            i -= 1;
            const d = self.active_decls.items[i];
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    fn addParamPattern(self: *ScopeAnalyzer, pattern: *const zstatements.BindingPattern) anyerror!void {
        switch (pattern.*) {
            .identifier => |identifier| {
                if (self.hasActiveAtDepth(identifier.name, 0)) return error.UnsupportedSyntax;
                const slot = try self.allocSlot(identifier.name, .parameter);
                try self.root_vars.put(self.allocator, identifier.name, slot);
                try self.active_decls.append(self.allocator, .{
                    .name = identifier.name,
                    .slot = slot,
                    .kind = .parameter,
                    .depth = 0,
                    .in_loop = false,
                });
                try self.decl_slots.put(self.allocator, @ptrCast(pattern), slot);
            },
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| try self.addParamPattern(element.pattern);
                if (array.rest) |rest| try self.addParamPattern(rest);
            },
            .object => |object| {
                for (object.properties) |property| try self.addParamPattern(property.value);
                if (object.rest) |rest| {
                    if (self.hasActiveAtDepth(rest.name, 0)) return error.UnsupportedSyntax;
                    const slot = try self.allocSlot(rest.name, .parameter);
                    try self.root_vars.put(self.allocator, rest.name, slot);
                    try self.active_decls.append(self.allocator, .{
                        .name = rest.name,
                        .slot = slot,
                        .kind = .parameter,
                        .depth = 0,
                        .in_loop = false,
                    });
                }
            },
        }
    }

    fn kindFor(variable_kind: zstatements.VariableKind) LocalKind {
        return switch (variable_kind) {
            .@"var" => .@"var",
            .let => .let,
            .@"const" => .@"const",
        };
    }

    fn predeclLexicalPattern(self: *ScopeAnalyzer, pattern: *const zstatements.BindingPattern, kind: LocalKind) anyerror!void {
        switch (pattern.*) {
            .identifier => |identifier| {
                if (self.hasActiveAtDepth(identifier.name, self.current_depth)) return error.UnsupportedSyntax;
                const slot = try self.allocSlot(identifier.name, kind);
                try self.active_decls.append(self.allocator, .{
                    .name = identifier.name,
                    .slot = slot,
                    .kind = kind,
                    .depth = self.current_depth,
                    .in_loop = self.loop_depth > 0,
                });
                try self.decl_slots.put(self.allocator, @ptrCast(pattern), slot);
            },
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| try self.predeclLexicalPattern(element.pattern, kind);
                if (array.rest) |rest| try self.predeclLexicalPattern(rest, kind);
            },
            .object => |object| {
                for (object.properties) |property| try self.predeclLexicalPattern(property.value, kind);
                if (object.rest) |rest| {
                    if (self.hasActiveAtDepth(rest.name, self.current_depth)) return error.UnsupportedSyntax;
                    const slot = try self.allocSlot(rest.name, kind);
                    try self.active_decls.append(self.allocator, .{
                        .name = rest.name,
                        .slot = slot,
                        .kind = kind,
                        .depth = self.current_depth,
                        .in_loop = self.loop_depth > 0,
                    });
                }
            },
        }
    }

    fn predeclDirectLexicals(self: *ScopeAnalyzer, stmts: anytype) anyerror!void {
        for (stmts) |stmt| {
            switch (stmt.data) {
                .variable => |variable| {
                    if (variable.kind != .@"var") {
                        const lkind = kindFor(variable.kind);
                        for (variable.declarators) |declarator| {
                            try self.predeclLexicalPattern(declarator.pattern, lkind);
                        }
                    }
                },
                .class_declaration => |ptr| {
                    if (zfunctions.asClassNode(ptr).name) |name| {
                        if (self.hasActiveAtDepth(name, self.current_depth)) return error.UnsupportedSyntax;
                        const slot = try self.allocSlot(name, .class);
                        try self.active_decls.append(self.allocator, .{
                            .name = name,
                            .slot = slot,
                            .kind = .class,
                            .depth = self.current_depth,
                            .in_loop = self.loop_depth > 0,
                        });
                    }
                },
                .function_declaration => {
                    if (self.current_depth > 0) return error.UnsupportedSyntax;
                },
                .export_decl => |item| if (item == .declaration) try self.predeclDirectLexicals(&[_]@TypeOf(item.declaration){item.declaration}),
                else => {},
            }
        }
    }

    fn predeclRootFunctions(self: *ScopeAnalyzer, stmts: anytype) anyerror!void {
        for (stmts) |stmt| {
            switch (stmt.data) {
                .function_declaration => |ptr| {
                    const name = zfunctions.asFunctionNode(ptr).kind.function_decl.name;
                    if (self.hasLexicalAtDepth(name, 0)) return error.UnsupportedSyntax;
                    if (self.root_vars.get(name) == null) {
                        const slot = try self.allocSlot(name, .function);
                        try self.root_vars.put(self.allocator, name, slot);
                        try self.active_decls.append(self.allocator, .{
                            .name = name,
                            .slot = slot,
                            .kind = .function,
                            .depth = 0,
                            .in_loop = false,
                        });
                    }
                },
                .export_decl => |item| if (item == .declaration) try self.predeclRootFunctions(&[_]@TypeOf(item.declaration){item.declaration}),
                else => {},
            }
        }
    }

    fn addRootVarName(self: *ScopeAnalyzer, name: []const u8) !u16 {
        if (self.hasLexicalAtDepth(name, 0)) return error.UnsupportedSyntax;
        if (self.root_vars.get(name)) |existing| return existing;
        const slot = try self.allocSlot(name, .@"var");
        try self.root_vars.put(self.allocator, name, slot);
        try self.active_decls.append(self.allocator, .{
            .name = name,
            .slot = slot,
            .kind = .@"var",
            .depth = 0,
            .in_loop = false,
        });
        return slot;
    }

    fn precollectVarPattern(self: *ScopeAnalyzer, pattern: *const zstatements.BindingPattern) anyerror!void {
        switch (pattern.*) {
            .identifier => |identifier| {
                const slot = try self.addRootVarName(identifier.name);
                try self.decl_slots.put(self.allocator, @ptrCast(pattern), slot);
            },
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| try self.precollectVarPattern(element.pattern);
                if (array.rest) |rest| try self.precollectVarPattern(rest);
            },
            .object => |object| {
                for (object.properties) |property| try self.precollectVarPattern(property.value);
                if (object.rest) |rest| _ = try self.addRootVarName(rest.name);
            },
        }
    }

    fn precollectVarsInStatements(self: *ScopeAnalyzer, stmts: anytype) anyerror!void {
        for (stmts) |stmt| try self.precollectVarsInStatement(stmt);
    }

    fn precollectVarsInStatement(self: *ScopeAnalyzer, statement: *const zstatements.Statement) anyerror!void {
        switch (statement.data) {
            .block => |items| for (items) |item| try self.precollectVarsInStatement(item),
            .variable => |variable| {
                if (variable.kind == .@"var") {
                    for (variable.declarators) |declarator| try self.precollectVarPattern(declarator.pattern);
                }
            },
            .if_stmt => |item| {
                try self.precollectVarsInStatement(item.consequent);
                if (item.alternate) |alternate| try self.precollectVarsInStatement(alternate);
            },
            .while_stmt => |item| try self.precollectVarsInStatement(item.body),
            .do_while => |item| try self.precollectVarsInStatement(item.body),
            .for_stmt => |item| {
                switch (item.head) {
                    .c_style => |head| if (head.init) |init| if (init == .decl and init.decl.kind == .@"var") {
                        for (init.decl.declarators) |declarator| try self.precollectVarPattern(declarator.pattern);
                    },
                    .for_in => |head| if (head.binding == .declared and head.binding.declared.kind == .@"var") {
                        try self.precollectVarPattern(head.binding.declared.pattern);
                    },
                    .for_of => |head| if (head.binding == .declared and head.binding.declared.kind == .@"var") {
                        try self.precollectVarPattern(head.binding.declared.pattern);
                    },
                }
                try self.precollectVarsInStatement(item.body);
            },
            .labelled => |item| try self.precollectVarsInStatement(item.body),
            .try_stmt => |item| {
                try self.precollectVarsInStatement(item.block);
                if (item.handler) |handler| try self.precollectVarsInStatement(handler.body);
                if (item.finalizer) |finalizer| try self.precollectVarsInStatement(finalizer);
            },
            .switch_stmt => |item| for (item.cases) |case| for (case.consequent) |child| try self.precollectVarsInStatement(child),
            .export_decl => |item| if (item == .declaration) try self.precollectVarsInStatement(item.declaration),
            else => {},
        }
    }

    fn checkVarPatternNoLexicalShadow(self: *const ScopeAnalyzer, pattern: *const zstatements.BindingPattern) anyerror!void {
        switch (pattern.*) {
            .identifier => |identifier| if (self.hasEnclosingLexical(identifier.name)) return error.UnsupportedSyntax,
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| try self.checkVarPatternNoLexicalShadow(element.pattern);
                if (array.rest) |rest| try self.checkVarPatternNoLexicalShadow(rest);
            },
            .object => |object| {
                for (object.properties) |property| try self.checkVarPatternNoLexicalShadow(property.value);
                if (object.rest) |rest| if (self.hasEnclosingLexical(rest.name)) return error.UnsupportedSyntax;
            },
        }
    }

    fn checkSubStatementAllowed(stmt: *const zstatements.Statement) anyerror!void {
        switch (stmt.data) {
            .function_declaration, .class_declaration => return error.UnsupportedSyntax,
            .variable => |v| if (v.kind != .@"var") return error.UnsupportedSyntax,
            else => {},
        }
    }

    fn addFree(self: *ScopeAnalyzer, name: []const u8) anyerror!void {
        if (self.resolveActive(name) != null or self.free_names.contains(name)) return;
        try self.free_names.put(self.allocator, name, {});
        try self.free.append(self.allocator, name);
    }

    fn markCaptured(self: *ScopeAnalyzer, name: []const u8) anyerror!void {
        if (self.captured_names.contains(name)) return;
        try self.captured_names.put(self.allocator, name, {});
        try self.captured.append(self.allocator, name);
    }

    fn walkStatement(self: *ScopeAnalyzer, statement: *const zstatements.Statement) anyerror!void {
        switch (statement.data) {
            .expr_stmt, .throw_stmt => |expression| try self.scanNode(expression),
            .block => |items| {
                const mark = self.active_decls.items.len;
                self.current_depth += 1;
                defer {
                    self.active_decls.items.len = mark;
                    self.current_depth -= 1;
                }
                try self.predeclDirectLexicals(items);
                for (items) |item| try self.walkStatement(item);
            },
            .variable => |variable| {
                if (variable.kind == .@"var") {
                    for (variable.declarators) |declarator| {
                        try self.checkVarPatternNoLexicalShadow(declarator.pattern);
                        if (declarator.init) |init| try self.scanNode(init);
                    }
                } else {
                    for (variable.declarators) |declarator| {
                        try self.scanPatternDefaults(declarator.pattern);
                        if (declarator.init) |init| try self.scanNode(init);
                    }
                }
            },
            .if_stmt => |item| {
                try checkSubStatementAllowed(item.consequent);
                if (item.alternate) |alt| try checkSubStatementAllowed(alt);
                try self.scanNode(item.test_expr);
                try self.walkStatement(item.consequent);
                if (item.alternate) |alternate| try self.walkStatement(alternate);
            },
            .while_stmt => |item| {
                try checkSubStatementAllowed(item.body);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.scanNode(item.test_expr);
                try self.walkStatement(item.body);
            },
            .do_while => |item| {
                try checkSubStatementAllowed(item.body);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.walkStatement(item.body);
                try self.scanNode(item.test_expr);
            },
            .for_stmt => |item| {
                try checkSubStatementAllowed(item.body);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                const mark = self.active_decls.items.len;
                var pushed_scope = false;
                defer if (pushed_scope) {
                    self.active_decls.items.len = mark;
                    self.current_depth -= 1;
                };
                switch (item.head) {
                    .c_style => |head| {
                        if (head.init) |init| switch (init) {
                            .decl => |variable| {
                                if (variable.kind == .@"var") {
                                    for (variable.declarators) |declarator| {
                                        try self.checkVarPatternNoLexicalShadow(declarator.pattern);
                                        if (declarator.init) |v_init| try self.scanNode(v_init);
                                    }
                                } else {
                                    self.current_depth += 1;
                                    pushed_scope = true;
                                    const lkind = kindFor(variable.kind);
                                    for (variable.declarators) |declarator| {
                                        try self.predeclLexicalPattern(declarator.pattern, lkind);
                                    }
                                    for (variable.declarators) |declarator| {
                                        try self.scanPatternDefaults(declarator.pattern);
                                        if (declarator.init) |v_init| try self.scanNode(v_init);
                                    }
                                }
                            },
                            .expr => |expr| try self.scanNode(expr),
                        };
                        if (head.test_expr) |test_expr| try self.scanNode(test_expr);
                        if (head.update) |update| try self.scanNode(update);
                    },
                    .for_in => |head| {
                        if (head.binding == .declared) {
                            if (head.binding.declared.kind == .@"var") {
                                try self.checkVarPatternNoLexicalShadow(head.binding.declared.pattern);
                            } else {
                                self.current_depth += 1;
                                pushed_scope = true;
                                try self.predeclLexicalPattern(head.binding.declared.pattern, kindFor(head.binding.declared.kind));
                            }
                        }
                        try self.scanNode(head.object);
                    },
                    .for_of => |head| {
                        if (head.binding == .declared) {
                            if (head.binding.declared.kind == .@"var") {
                                try self.checkVarPatternNoLexicalShadow(head.binding.declared.pattern);
                            } else {
                                self.current_depth += 1;
                                pushed_scope = true;
                                try self.predeclLexicalPattern(head.binding.declared.pattern, kindFor(head.binding.declared.kind));
                            }
                        }
                        try self.scanNode(head.iterable);
                    },
                }
                try self.walkStatement(item.body);
            },
            .return_stmt => |value| if (value) |expression| try self.scanNode(expression),
            .labelled => |item| {
                if (item.body.data == .function_declaration) return error.UnsupportedSyntax;
                try checkSubStatementAllowed(item.body);
                try self.walkStatement(item.body);
            },
            .try_stmt => |item| {
                try self.walkStatement(item.block);
                if (item.handler) |handler| {
                    const mark = self.active_decls.items.len;
                    self.current_depth += 1;
                    defer {
                        self.active_decls.items.len = mark;
                        self.current_depth -= 1;
                    }
                    if (handler.param) |param| {
                        try self.predeclLexicalPattern(param, .catch_binding);
                        try self.scanPatternDefaults(param);
                    }
                    if (handler.body.data == .block) {
                        try self.predeclDirectLexicals(handler.body.data.block);
                        for (handler.body.data.block) |child| try self.walkStatement(child);
                    } else {
                        try self.walkStatement(handler.body);
                    }
                }
                if (item.finalizer) |finalizer| try self.walkStatement(finalizer);
            },
            .switch_stmt => |item| {
                const mark = self.active_decls.items.len;
                self.current_depth += 1;
                defer {
                    self.active_decls.items.len = mark;
                    self.current_depth -= 1;
                }
                try self.scanNode(item.discriminant);
                for (item.cases) |case| try self.predeclDirectLexicals(case.consequent);
                for (item.cases) |case| {
                    if (case.test_expr) |test_expr| try self.scanNode(test_expr);
                    for (case.consequent) |child| try self.walkStatement(child);
                }
            },
            .with_stmt => |item| {
                try self.scanNode(item.object);
                try self.walkStatement(item.body);
            },
            .function_declaration => |ptr| {
                if (self.current_depth > 0) return error.UnsupportedSyntax;
                try self.scanNested(zfunctions.asFunctionNode(ptr));
            },
            .class_declaration => |ptr| try self.scanClass(zfunctions.asClassNode(ptr)),
            .export_decl => |item| switch (item) {
                .declaration => |decl| try self.walkStatement(decl),
                .default => |expression| try self.scanNode(expression),
                else => {},
            },
            else => {},
        }
    }

    fn scanPatternDefaults(self: *ScopeAnalyzer, pattern: *const zstatements.BindingPattern) anyerror!void {
        switch (pattern.*) {
            .identifier => {},
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| {
                    try self.scanPatternDefaults(element.pattern);
                    if (element.default) |def_node| try self.scanNode(def_node);
                };
                if (array.rest) |rest| try self.scanPatternDefaults(rest);
            },
            .object => |object| {
                for (object.properties) |property| {
                    if (property.computed_key) |ck| try self.scanNode(ck);
                    try self.scanPatternDefaults(property.value);
                    if (property.default) |def_node| try self.scanNode(def_node);
                }
            },
        }
    }

    fn scanNested(self: *ScopeAnalyzer, nested: *const zfunctions.FunctionNode) anyerror!void {
        self.has_nested_fn = true;
        var analysis = try ScopeAnalyzer.analyze(self.allocator, nested);
        defer analysis.deinit(self.allocator);
        if (analysis.flags.has_super) self.has_super = true;
        for (analysis.free_names) |name| {
            if (self.resolveActive(name)) |decl| {
                const is_scoped_lex = switch (decl.kind) {
                    .let, .@"const", .class, .catch_binding => decl.depth > 0 or decl.in_loop,
                    else => false,
                };
                if (is_scoped_lex) return error.UnsupportedSyntax;
                try self.markCaptured(name);
            } else {
                try self.addFree(name);
            }
        }
    }

    fn scanClass(self: *ScopeAnalyzer, class: *const zfunctions.ClassNode) anyerror!void {
        if (class.superclass) |superclass| try self.scanNode(superclass);
        for (class.elements) |element| {
            switch (element.key) {
                .computed => |key| try self.scanNode(key),
                else => {},
            }
            if (element.value) |value| try self.scanNode(value);
            if (element.function) |function| try self.scanNested(function);
        }
    }

    fn scanNode(self: *ScopeAnalyzer, node: *const zparser.Node) anyerror!void {
        switch (node.data) {
            .identifier => |name| try self.addFree(name),
            .template_literal => |template| for (template.expressions) |expression| try self.scanNode(expression),
            .tagged_template => |template| {
                try self.scanNode(template.tag);
                for (template.expressions) |expression| try self.scanNode(expression);
            },
            .array_literal => |items| for (items) |item| if (item) |expression| try self.scanNode(expression),
            .object_literal => |items| for (items) |item| switch (item) {
                .spread => |expression| try self.scanNode(expression),
                .property => |property| {
                    if (property.computed) try self.scanNode(property.key);
                    try self.scanNode(property.value);
                },
            },
            .spread, .paren, .await_expr => |operand| try self.scanNode(operand),
            .unary => |unary| try self.scanNode(unary.operand),
            .binary => |binary| {
                try self.scanNode(binary.left);
                try self.scanNode(binary.right);
            },
            .logical => |logical| {
                try self.scanNode(logical.left);
                try self.scanNode(logical.right);
            },
            .assignment => |assignment| {
                try self.scanNode(assignment.target);
                try self.scanNode(assignment.value);
            },
            .conditional => |conditional| {
                try self.scanNode(conditional.test_expr);
                try self.scanNode(conditional.consequent);
                try self.scanNode(conditional.alternate);
            },
            .sequence => |items| for (items) |item| try self.scanNode(item),
            .call => |call| {
                try self.scanNode(call.callee);
                for (call.args) |argument| try self.scanNode(argument);
            },
            .new_expr => |new_expr| {
                try self.scanNode(new_expr.callee);
                if (new_expr.args) |args| for (args) |argument| try self.scanNode(argument);
            },
            .member => |member| {
                try self.scanNode(member.object);
                if (member.computed) try self.scanNode(member.property);
            },
            .function_like => |ptr| try self.scanNested(zfunctions.asFunctionNode(ptr)),
            .class_like => |ptr| try self.scanClass(zfunctions.asClassNode(ptr)),
            .yield_expr => |yield_expr| if (yield_expr.argument) |argument| try self.scanNode(argument),
            .super_expr, .new_target => self.has_super = true,
            else => {},
        }
    }
};

test "scope analyzer assigns parameter and local slots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function f(a, b) { var c = a; let d = b; const e = c; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var analysis = try ScopeAnalyzer.analyze(std.testing.allocator, function);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u16, 0), analysis.localSlot("a"));
    try std.testing.expectEqual(@as(?u16, 1), analysis.localSlot("b"));
    try std.testing.expectEqual(@as(?u16, 2), analysis.localSlot("c"));
    try std.testing.expectEqual(@as(?u16, 3), analysis.localSlot("d"));
    try std.testing.expectEqual(@as(?u16, 4), analysis.localSlot("e"));
    try std.testing.expectEqual(@as(u16, 5), analysis.register_count);
}

test "scope analyzer marks locals captured by a nested closure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function outer(x) { let y = 1; return function inner() { return x + y + global; }; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var analysis = try ScopeAnalyzer.analyze(std.testing.allocator, function);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expect(analysis.capturesLocal("x"));
    try std.testing.expect(analysis.capturesLocal("y"));
    try std.testing.expectEqual(@as(usize, 1), analysis.free_names.len);
    try std.testing.expectEqualStrings("global", analysis.free_names[0]);
}

test "scope analyzer assigns distinct slots for shadowed let/const and rejects for-let closures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p1 = try zfunctions.Parser.init(arena_state.allocator(), "function f(x) { let a = 1; { let a = 2; const x = 3; } for (let i = 0; i < 4; i++) {} for (let i = 0; i < 4; i++) {} }");
    const s1 = try p1.parseStatement();
    var a1 = try ScopeAnalyzer.analyze(std.testing.allocator, zfunctions.asFunctionNode(s1.data.function_declaration));
    defer a1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 6), a1.local_count);

    const p2 = try zfunctions.Parser.init(arena_state.allocator(), "function g() { for (let i = 0; i < 3; i++) { const fn = () => i; } }");
    const s2 = try p2.parseStatement();
    try std.testing.expectError(error.UnsupportedSyntax, ScopeAnalyzer.analyze(std.testing.allocator, zfunctions.asFunctionNode(s2.data.function_declaration)));
}
