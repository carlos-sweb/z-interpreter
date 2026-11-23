//! Step 5 Phase C batch 4: the class+private+closures cluster --
//! class evaluation, private-field machinery, and closure creation.
//! Split out of interpreter.zig; see z-interpreter-refactor.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zfunctions = @import("zfunctions");
const zstatements = @import("zstatements");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const coercion = @import("coercion.zig");
const bytecode_emitter = @import("bytecode/emitter.zig");
const bytecode_vm = @import("bytecode/vm.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const ClassCtx = interpreter_mod.ClassCtx;
const ClosureCtx = interpreter_mod.ClosureCtx;
const FieldDef = interpreter_mod.FieldDef;

/// ECMA-262 15.1.3 ExpectedArgumentCount: leading parameters up to (not
/// including) the first one with a default -- NOT `params.items.len`,
/// which counts every declared parameter regardless of defaults. A rest
/// parameter (`params.rest`, tracked separately from `.items` in this
/// AST) never adds to the count either way, so it needs no special
/// case here.
fn expectedArgumentCount(params: zfunctions.Params) usize {
    var count: usize = 0;
    for (params.items) |p| {
        if (p.default != null) break;
        count += 1;
    }
    return count;
}

/// Unwraps `(expr)` nodes -- real spec's `IsAnonymousFunctionDefinition`
/// looks through parenthesization (`let x = (() => {})` still names `x`,
/// confirmed against real Node), but this AST keeps `paren` as its own
/// node (semantically load-bearing elsewhere, e.g. `(-2) ** 2`), so
/// every syntactic check below has to see past it explicitly.
fn unwrapParen(node: *const zparser.Node) *const zparser.Node {
    var n = node;
    while (n.data == .paren) n = n.data.paren;
    return n;
}

/// ECMA-262 `IsAnonymousFunctionDefinition`: true only for a
/// FunctionExpression/GeneratorExpression/AsyncFunctionExpression/
/// AsyncGeneratorExpression with no BindingIdentifier, or an
/// ArrowFunction/AsyncArrowFunction (always anonymous by grammar) --
/// NOT "any expression that happens to evaluate to a function" (e.g.
/// `let x = make()` never triggers this, even if `make()` returns an
/// anonymous arrow). Generator/async-ness is an orthogonal flag on the
/// same `FunctionNode`, so no separate check is needed for those.
fn isAnonFnNode(node: *const zparser.Node) bool {
    const n = unwrapParen(node);
    if (n.data != .function_like) return false;
    const fnode = zfunctions.asFunctionNode(n.data.function_like);
    return switch (fnode.kind) {
        .arrow => true,
        .function_expr => |e| e.name == null,
        .function_decl, .method => false,
    };
}

/// Same idea as `isAnonFnNode`, for `ClassExpression` with no
/// `BindingIdentifier`.
fn isAnonClassNode(node: *const zparser.Node) bool {
    const n = unwrapParen(node);
    if (n.data != .class_like) return false;
    return zfunctions.asClassNode(n.data.class_like).name == null;
}

/// ECMA-262 NamedEvaluation: if `init_node` is syntactically one of the
/// anonymous-function-definition productions above, and the value it
/// evaluated to is a nameless `.function`, gives it `name` -- the
/// SetFunctionName step every named binding/assignment/property-value/
/// default/class-field context has to run. `name` is always dupe'd
/// rather than trusted to outlive the call (some callers -- e.g. a
/// computed object-literal property key -- free their copy before this
/// returns) -- onto `arena_state`, NOT `gc_allocator`: `Callable.name`
/// is never freed by `Callable.deinit()` (every existing name is an
/// AST-borrowed slice, permanent for the parse tree's lifetime), so a
/// `gc_allocator` dupe here would leak on every rename (confirmed: it
/// did, before this fix, showing up as a real leaked-allocation in
/// nearly every test that declares a named const/let arrow). `arena_
/// state` is the same "AST-adjacent, freed once at shutdown, never
/// individually freed" category this codebase already uses for exactly
/// this kind of permanent-but-not-GC-traced string.
pub fn setFunctionName(self: *Interpreter, value: JSValue, key_str: []const u8, prefix: ?[]const u8) anyerror!void {
    if (!value.isFunction()) return;
    const alloc = self.arena_state.allocator();
    var base: []const u8 = key_str;
    if (key_str.len >= 2 and key_str[0] == 0 and key_str[1] == 'S') {
        if (self.symbol_keys.get(key_str)) |sym| {
            if (sym.asSymbol().value.description) |desc| {
                base = try std.fmt.allocPrint(alloc, "[{s}]", .{desc});
            } else {
                base = "";
            }
        } else {
            base = "";
        }
    } else if (key_str.len > 0 and key_str[0] == 0) {
        base = fieldDisplayName(key_str);
    }
    if (prefix) |p| {
        value.asFunction().value.name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ p, base });
    } else {
        value.asFunction().value.name = try alloc.dupe(u8, base);
    }
}

pub fn maybeNameAnonymousValue(self: *Interpreter, init_node: *const zparser.Node, value: JSValue, name: []const u8) anyerror!void {
    if (!isAnonFnNode(init_node) and !isAnonClassNode(init_node)) return;
    if (!value.isFunction() or value.asFunction().value.name.len != 0) return;
    try setFunctionName(self, value, name, null);
}

/// Recovers a class-field key's readable source name for NamedEvaluation:
/// a private key is encoded as `\x00P<hex>|#name` (see `encodePrivateKey`
/// -- the source lexeme already includes its own `#`, so the part after
/// the last `|` matches real spec's "#name" PrivateName display exactly).
/// A plain (public) key is used as-is.
fn fieldDisplayName(key: []const u8) []const u8 {
    if (key.len == 0 or key[0] != 0) return key;
    if (std.mem.lastIndexOfScalar(u8, key, '|')) |i| return key[i + 1 ..];
    return key;
}

/// A deliberately conservative lexical scan. Returning true for syntax we do
/// not traverse preserves the old eager behavior; only a proven absence of an
/// `arguments` identifier skips allocation. Nested ordinary functions own
/// their arguments, while nested arrows inherit the enclosing binding.
fn functionNeedsArguments(self: *Interpreter, fnode: *zfunctions.FunctionNode) bool {
    if (fnode.kind == .arrow) return false;
    const key = @intFromPtr(fnode);
    if (self.function_needs_arguments.get(key)) |cached| return cached;
    const needs = functionBodyUsesArguments(fnode);
    self.function_needs_arguments.put(self.gc_allocator, key, needs) catch return true;
    return needs;
}

fn functionBodyUsesArguments(fnode: *const zfunctions.FunctionNode) bool {
    for (fnode.params.items) |param| {
        if (bindingPatternBindsName(param.pattern, "arguments")) return false;
    }
    if (fnode.params.rest) |rest| {
        if (bindingPatternBindsName(rest, "arguments")) return false;
    }
    for (fnode.params.items) |param| {
        if (bindingPatternUsesArguments(param.pattern)) return true;
        if (param.default) |default_value| if (nodeUsesArguments(default_value)) return true;
    }
    if (fnode.params.rest) |rest| if (bindingPatternUsesArguments(rest)) return true;
    return switch (fnode.body) {
        .block => |body| statementUsesArguments(body),
        .expression => |body| nodeUsesArguments(body),
    };
}

fn bindingPatternBindsName(pattern: *const zstatements.BindingPattern, target: []const u8) bool {
    return switch (pattern.*) {
        .identifier => |id| std.mem.eql(u8, id.name, target),
        .array => |array| blk: {
            for (array.elements) |element| if (element) |item| {
                if (bindingPatternBindsName(item.pattern, target)) break :blk true;
            };
            if (array.rest) |rest| if (bindingPatternBindsName(rest, target)) break :blk true;
            break :blk false;
        },
        .object => |object| blk: {
            for (object.properties) |property| {
                if (bindingPatternBindsName(property.value, target)) break :blk true;
            }
            if (object.rest) |rest| if (std.mem.eql(u8, rest.name, target)) break :blk true;
            break :blk false;
        },
    };
}

fn markParamPatternTDZ(env: *Environment, allocator: Allocator, pattern: *const zstatements.BindingPattern) !void {
    switch (pattern.*) {
        .identifier => |id| if (!env.containsBinding(id.name)) try env.markTDZ(allocator, id.name),
        .array => |array| {
            for (array.elements) |element| if (element) |item| {
                try markParamPatternTDZ(env, allocator, item.pattern);
            };
            if (array.rest) |rest| try markParamPatternTDZ(env, allocator, rest);
        },
        .object => |object| {
            for (object.properties) |property| {
                try markParamPatternTDZ(env, allocator, property.value);
            }
            if (object.rest) |rest| if (!env.containsBinding(rest.name)) try env.markTDZ(allocator, rest.name);
        },
    }
}

fn bindingPatternUsesArguments(pattern: *const zstatements.BindingPattern) bool {
    return switch (pattern.*) {
        .identifier => false,
        .array => |array| blk: {
            for (array.elements) |element| if (element) |item| {
                if (bindingPatternUsesArguments(item.pattern)) break :blk true;
                if (item.default) |default_value| if (nodeUsesArguments(default_value)) break :blk true;
            };
            if (array.rest) |rest| if (bindingPatternUsesArguments(rest)) break :blk true;
            break :blk false;
        },
        .object => |object| blk: {
            for (object.properties) |property| {
                if (property.computed_key) |ck| if (nodeUsesArguments(ck)) break :blk true;
                if (bindingPatternUsesArguments(property.value)) break :blk true;
                if (property.default) |default_value| if (nodeUsesArguments(default_value)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn nodeUsesArguments(node: *const zparser.Node) bool {
    return switch (node.data) {
        .identifier => |name| std.mem.eql(u8, name, "arguments"),
        .template_literal => |template| blk: {
            for (template.expressions) |expression| if (nodeUsesArguments(expression)) break :blk true;
            break :blk false;
        },
        .array_literal => |items| blk: {
            for (items) |item| if (item) |expression| if (nodeUsesArguments(expression)) break :blk true;
            break :blk false;
        },
        .object_literal => |items| blk: {
            for (items) |item| switch (item) {
                .spread => |expression| if (nodeUsesArguments(expression)) break :blk true,
                .property => |property| {
                    if (property.computed and nodeUsesArguments(property.key)) break :blk true;
                    if (nodeUsesArguments(property.value)) break :blk true;
                },
            };
            break :blk false;
        },
        .spread, .paren, .await_expr => |operand| nodeUsesArguments(operand),
        .unary => |unary| nodeUsesArguments(unary.operand),
        .binary => |binary| nodeUsesArguments(binary.left) or nodeUsesArguments(binary.right),
        .logical => |logical| nodeUsesArguments(logical.left) or nodeUsesArguments(logical.right),
        .assignment => |assignment| nodeUsesArguments(assignment.target) or nodeUsesArguments(assignment.value),
        .conditional => |conditional| nodeUsesArguments(conditional.test_expr) or nodeUsesArguments(conditional.consequent) or nodeUsesArguments(conditional.alternate),
        .sequence => |items| blk: {
            for (items) |item| if (nodeUsesArguments(item)) break :blk true;
            break :blk false;
        },
        .call => |call| blk: {
            if (nodeUsesArguments(call.callee)) break :blk true;
            for (call.args) |argument| if (nodeUsesArguments(argument)) break :blk true;
            break :blk false;
        },
        .new_expr => |new_expr| blk: {
            if (nodeUsesArguments(new_expr.callee)) break :blk true;
            if (new_expr.args) |args| for (args) |argument| if (nodeUsesArguments(argument)) break :blk true;
            break :blk false;
        },
        .member => |member| nodeUsesArguments(member.object) or (member.computed and nodeUsesArguments(member.property)),
        .function_like => |function_ptr| blk: {
            const nested = zfunctions.asFunctionNode(function_ptr);
            break :blk nested.kind == .arrow and functionBodyUsesArguments(nested);
        },
        // A class can evaluate an outer lexical `arguments` in heritage,
        // computed names, or field initializers. Keep the eager path until
        // that AST has a dedicated scanner.
        .class_like => true,
        .yield_expr => |yield_expr| if (yield_expr.argument) |argument| nodeUsesArguments(argument) else false,
        .number_literal, .bigint_literal, .string_literal, .boolean_literal, .null_literal, .regex_literal, .this_expr, .super_expr, .new_target => false,
    };
}

fn statementUsesArguments(statement: *const zstatements.Statement) bool {
    return switch (statement.data) {
        .empty, .continue_stmt, .break_stmt, .debugger, .import_decl, .function_declaration => false,
        .expr_stmt, .throw_stmt => |expression| nodeUsesArguments(expression),
        .block => |statements| blk: {
            for (statements) |child| if (statementUsesArguments(child)) break :blk true;
            break :blk false;
        },
        .variable => |variable| blk: {
            for (variable.declarators) |declarator| {
                if (bindingPatternUsesArguments(declarator.pattern)) break :blk true;
                if (declarator.init) |init| if (nodeUsesArguments(init)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => |if_stmt| nodeUsesArguments(if_stmt.test_expr) or statementUsesArguments(if_stmt.consequent) or (if_stmt.alternate != null and statementUsesArguments(if_stmt.alternate.?)),
        .while_stmt => |loop| nodeUsesArguments(loop.test_expr) or statementUsesArguments(loop.body),
        .do_while => |loop| statementUsesArguments(loop.body) or nodeUsesArguments(loop.test_expr),
        .for_stmt, .try_stmt, .switch_stmt, .labelled, .with_stmt, .class_declaration, .export_decl => true,
        .return_stmt => |value| if (value) |expression| nodeUsesArguments(expression) else false,
    };
}

fn functionMayEscape(fnode: *const zfunctions.FunctionNode) bool {
    if (fnode.is_generator or fnode.is_async) return true;
    if (fnode.params.rest != null) return true;
    for (fnode.params.items) |param| {
        if (param.default != null) return true;
        if (param.pattern.* != .identifier) return true;
    }
    return switch (fnode.body) {
        .block => |body| statementMayEscape(body),
        .expression => |body| nodeMayEscape(body),
    };
}

fn nodeMayEscape(node: *const zparser.Node) bool {
    return switch (node.data) {
        .function_like, .class_like, .yield_expr, .await_expr => true,
        .identifier => |name| std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments"),
        .unary => |u| nodeMayEscape(u.operand),
        .binary => |b| nodeMayEscape(b.left) or nodeMayEscape(b.right),
        .logical => |l| nodeMayEscape(l.left) or nodeMayEscape(l.right),
        .assignment => |a| nodeMayEscape(a.target) or nodeMayEscape(a.value),
        .conditional => |c| nodeMayEscape(c.test_expr) or nodeMayEscape(c.consequent) or nodeMayEscape(c.alternate),
        .paren, .spread => |op| nodeMayEscape(op),
        .call => |c| blk: {
            if (nodeMayEscape(c.callee)) break :blk true;
            for (c.args) |arg| if (nodeMayEscape(arg)) break :blk true;
            break :blk false;
        },
        .member => |m| nodeMayEscape(m.object) or (m.computed and nodeMayEscape(m.property)),
        else => false,
    };
}

fn statementMayEscape(stmt: *const zstatements.Statement) bool {
    return switch (stmt.data) {
        .function_declaration, .class_declaration => true,
        .expr_stmt, .throw_stmt => |e| nodeMayEscape(e),
        .return_stmt => |v| if (v) |e| nodeMayEscape(e) else false,
        .block => |stmts| blk: {
            for (stmts) |s| if (statementMayEscape(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |s| nodeMayEscape(s.test_expr) or statementMayEscape(s.consequent) or (s.alternate != null and statementMayEscape(s.alternate.?)),
        .while_stmt => |s| nodeMayEscape(s.test_expr) or statementMayEscape(s.body),
        .do_while => |s| statementMayEscape(s.body) or nodeMayEscape(s.test_expr),
        else => true,
    };
}

pub fn makeClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode) anyerror!JSValue {
    const arena = self.gc_allocator;
    // A named function expression's own name is visible inside its own
    // body (for self-recursion) even though it isn't bound in the
    // enclosing scope -- bind it in a thin wrapper env between `env`
    // and the closure's actual defining environment.
    const self_name: ?[]const u8 = switch (fnode.kind) {
        .function_expr => |e| e.name,
        else => null,
    };
    const closure_env = if (self_name != null) try self.gcChildEnv(env) else env;
    closure_env.escaping = true;
    try self.gcTrackEnvironment(closure_env);

    const ctx = try arena.create(ClosureCtx);
    ctx.* = .{ .interp = self, .function_node = fnode, .closure_env = closure_env, .source_full = self.current_source };
    try self.gcTrackClosureCtx(ctx);
    const name: []const u8 = switch (fnode.kind) {
        .function_decl => |d| d.name,
        .function_expr => |e| e.name orelse "",
        .method => |m| m.name,
        .arrow => "",
    };
    const fn_value = try self.gcNewFunction(.{
        .ctx = ctx,
        .name = name,
        .arity = expectedArgumentCount(fnode.params),
        .call = closureCall,
        // Arrows and object-literal methods are not constructors
        // (spec); natives keep the default false via their own
        // newFunction call sites.
        .constructable = switch (fnode.kind) {
            .arrow, .method => false,
            .function_decl, .function_expr => true,
        },
    });
    if (self_name) |n| {
        try closure_env.define(arena, n, fn_value.retain());
        // immutable-bindings.md: a named function expression's own
        // self-reference is a CreateImmutableBinding (ECMA-262
        // InstantiateOrdinaryFunctionExpression) -- `(function g(){
        // g = 1; })()` is a real TypeError, confirmed against Node.
        try closure_env.markConst(arena, n);
    }
    return fn_value;
}

/// A class-body method closure: an ordinary makeClosure whose
/// ClosureCtx additionally carries the parent prototype (so `super.m()`
/// resolves inside the body) and the declaring class's private identity
/// (so `this.#x` resolves). Safe cast: makeClosure always installs a
/// ClosureCtx as the ctx of the closures it creates.
pub fn makeMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, super_proto: ?JSValue, private_ctx: ?*anyopaque) anyerror!JSValue {
    const v = try self.makeClosure(env, fnode);
    const cc: *ClosureCtx = @ptrCast(@alignCast(v.asFunction().value.ctx));
    // Etapa 2 de uniform-ownership-contract.md: ClosureCtx lives as
    // long as the function value itself, same "no dedicated release"
    // shape as Environment's this_value/super_proto -- needs its own
    // retained copy now that a discarded value can actually be freed.
    if (super_proto) |sp| cc.super_proto = sp.retain();
    cc.private_ctx = private_ctx;
    return v;
}

/// An object-literal method/getter/setter closure: an ordinary
/// makeClosure whose ClosureCtx additionally carries the object literal
/// itself as [[HomeObject]] (see Environment.home_object's doc comment
/// for why this is a distinct mechanism from makeMethodClosure's
/// super_proto -- dynamic prototype lookup vs. a class's fixed
/// snapshot). `home` must be the `.object` JSValue being built by the
/// enclosing object-literal evaluation.
pub fn makeObjectMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, home: JSValue) anyerror!JSValue {
    const v = try self.makeClosure(env, fnode);
    const cc: *ClosureCtx = @ptrCast(@alignCast(v.asFunction().value.ctx));
    cc.home_object = home.retain();
    return v;
}

// ===== Private (`#name`) member machinery =====
//
// ECMA-262's PrivateEnvironment/PrivateName pair, collapsed onto the
// existing property model: each class's ClassCtx pointer IS its private
// identity, and `#name` members are stored as ordinary properties under
// the reserved key `\x00P{ctx}|{name}` -- the `\x00` prefix is already
// invisible to every enumeration path (Object.keys, for-in, JSON,
// getOwnPropertyNames all skip it), so privates are non-reflective for
// free. The BRAND CHECK falls out of key mismatch: another class's
// `#name` encodes to a different key, and a miss is the spec TypeError.

/// Encodes a private member's storage key for a given class identity.
pub fn encodePrivateKey(self: *Interpreter, class_id: *anyopaque, name: []const u8) ![]const u8 {
    const bare = if (name.len > 0 and name[0] == '#') name[1..] else name;
    return std.fmt.allocPrint(self.gc_allocator, "\x00P{x}|#{s}", .{ @intFromPtr(class_id), bare });
}

pub fn normalizePrivateInProgram(allocator: Allocator, source: []const u8, stmts: []const *zstatements.Statement) anyerror!void {
    for (stmts) |stmt| try normalizePrivateInStatement(allocator, source, stmt);
}

fn normalizePrivateInPattern(allocator: Allocator, source: []const u8, pattern: *const zstatements.BindingPattern) anyerror!void {
    switch (pattern.*) {
        .identifier => {},
        .array => |arr| {
            for (arr.elements) |maybe_el| if (maybe_el) |el| {
                try normalizePrivateInPattern(allocator, source, el.pattern);
                if (el.default) |d| try normalizePrivateInNode(allocator, source, d);
            };
            if (arr.rest) |r| try normalizePrivateInPattern(allocator, source, r);
        },
        .object => |obj| {
            for (obj.properties) |p| {
                if (p.computed_key) |ck| try normalizePrivateInNode(allocator, source, ck);
                try normalizePrivateInPattern(allocator, source, p.value);
                if (p.default) |d| try normalizePrivateInNode(allocator, source, d);
            }
        },
    }
}

fn normalizePrivateInFunction(allocator: Allocator, source: []const u8, fnode: *zfunctions.FunctionNode) anyerror!void {
    for (fnode.params.items) |param| {
        try normalizePrivateInPattern(allocator, source, param.pattern);
        if (param.default) |d| try normalizePrivateInNode(allocator, source, d);
    }
    if (fnode.params.rest) |r| try normalizePrivateInPattern(allocator, source, r);
    switch (fnode.body) {
        .block => |b| try normalizePrivateInStatement(allocator, source, b),
        .expression => |e| try normalizePrivateInNode(allocator, source, e),
    }
}

fn normalizePrivateInClass(allocator: Allocator, source: []const u8, cnode: *zfunctions.ClassNode) anyerror!void {
    if (cnode.superclass) |sc| try normalizePrivateInNode(allocator, source, sc);
    for (cnode.elements) |el| {
        switch (el.key) {
            .private => |n| {
                if ((n.len == 0 or n[0] != '#') and el.function != null) {
                    const fn_node = el.function.?;
                    if (fn_node.kind == .method) {
                        fn_node.kind = .{ .method = .{ .name = try std.fmt.allocPrint(allocator, "#{s}", .{n}) } };
                    }
                }
            },
            .computed => |expr| try normalizePrivateInNode(allocator, source, expr),
            .ident => {},
        }
        if (el.function) |fn_node| try normalizePrivateInFunction(allocator, source, fn_node);
        if (el.value) |vexpr| try normalizePrivateInNode(allocator, source, vexpr);
    }
}

fn normalizePrivateInStatement(allocator: Allocator, source: []const u8, stmt: *const zstatements.Statement) anyerror!void {
    switch (stmt.data) {
        .empty, .continue_stmt, .break_stmt, .debugger, .import_decl => {},
        .expr_stmt, .throw_stmt => |e| try normalizePrivateInNode(allocator, source, e),
        .return_stmt => |maybe_e| if (maybe_e) |e| try normalizePrivateInNode(allocator, source, e),
        .block => |stmts| try normalizePrivateInProgram(allocator, source, stmts),
        .variable => |v| for (v.declarators) |decl| {
            try normalizePrivateInPattern(allocator, source, decl.pattern);
            if (decl.init) |init| try normalizePrivateInNode(allocator, source, init);
        },
        .if_stmt => |s| {
            try normalizePrivateInNode(allocator, source, s.test_expr);
            try normalizePrivateInStatement(allocator, source, s.consequent);
            if (s.alternate) |alt| try normalizePrivateInStatement(allocator, source, alt);
        },
        .while_stmt => |s| {
            try normalizePrivateInNode(allocator, source, s.test_expr);
            try normalizePrivateInStatement(allocator, source, s.body);
        },
        .do_while => |s| {
            try normalizePrivateInStatement(allocator, source, s.body);
            try normalizePrivateInNode(allocator, source, s.test_expr);
        },
        .for_stmt => |s| {
            switch (s.head) {
                .c_style => |h| {
                    if (h.init) |ic| switch (ic) {
                        .decl => |d| for (d.declarators) |decl| {
                            try normalizePrivateInPattern(allocator, source, decl.pattern);
                            if (decl.init) |init| try normalizePrivateInNode(allocator, source, init);
                        },
                        .expr => |e| try normalizePrivateInNode(allocator, source, e),
                    };
                    if (h.test_expr) |te| try normalizePrivateInNode(allocator, source, te);
                    if (h.update) |up| try normalizePrivateInNode(allocator, source, up);
                },
                .for_in => |h| {
                    switch (h.binding) {
                        .declared => |d| try normalizePrivateInPattern(allocator, source, d.pattern),
                        .existing => {},
                        .existing_pattern => |e| try normalizePrivateInNode(allocator, source, e),
                    }
                    try normalizePrivateInNode(allocator, source, h.object);
                },
                .for_of => |h| {
                    switch (h.binding) {
                        .declared => |d| try normalizePrivateInPattern(allocator, source, d.pattern),
                        .existing => {},
                        .existing_pattern => |e| try normalizePrivateInNode(allocator, source, e),
                    }
                    try normalizePrivateInNode(allocator, source, h.iterable);
                },
            }
            try normalizePrivateInStatement(allocator, source, s.body);
        },
        .labelled => |s| try normalizePrivateInStatement(allocator, source, s.body),
        .try_stmt => |s| {
            try normalizePrivateInStatement(allocator, source, s.block);
            if (s.handler) |h| {
                if (h.param) |p| try normalizePrivateInPattern(allocator, source, p);
                try normalizePrivateInStatement(allocator, source, h.body);
            }
            if (s.finalizer) |fin| try normalizePrivateInStatement(allocator, source, fin);
        },
        .switch_stmt => |s| {
            try normalizePrivateInNode(allocator, source, s.discriminant);
            for (s.cases) |c| {
                if (c.test_expr) |te| try normalizePrivateInNode(allocator, source, te);
                try normalizePrivateInProgram(allocator, source, c.consequent);
            }
        },
        .with_stmt => |s| {
            try normalizePrivateInNode(allocator, source, s.object);
            try normalizePrivateInStatement(allocator, source, s.body);
        },
        .function_declaration => |ptr| try normalizePrivateInFunction(allocator, source, zfunctions.asFunctionNode(ptr)),
        .class_declaration => |ptr| try normalizePrivateInClass(allocator, source, zfunctions.asClassNode(ptr)),
        .export_decl => |e| switch (e) {
            .declaration => |inner| try normalizePrivateInStatement(allocator, source, inner),
            .default => |expr| try normalizePrivateInNode(allocator, source, expr),
            .named, .all => {},
        },
    }
}

pub fn normalizePrivateInNode(allocator: Allocator, source: []const u8, node: *zparser.Node) anyerror!void {
    switch (node.data) {
        .identifier => |*name| {
            if (node.start < source.len and source[node.start] == '#' and (name.len == 0 or name.*[0] != '#')) {
                name.* = try std.fmt.allocPrint(allocator, "#{s}", .{name.*});
            }
        },
        .template_literal => |t| for (t.expressions) |e| try normalizePrivateInNode(allocator, source, e),
        .array_literal => |items| for (items) |maybe_e| if (maybe_e) |e| try normalizePrivateInNode(allocator, source, e),
        .object_literal => |items| for (items) |item| switch (item) {
            .spread => |e| try normalizePrivateInNode(allocator, source, e),
            .property => |p| {
                if (p.computed) try normalizePrivateInNode(allocator, source, p.key);
                try normalizePrivateInNode(allocator, source, p.value);
            },
        },
        .spread, .paren, .await_expr => |op| try normalizePrivateInNode(allocator, source, op),
        .unary => |u| try normalizePrivateInNode(allocator, source, u.operand),
        .binary => |b| {
            try normalizePrivateInNode(allocator, source, b.left);
            try normalizePrivateInNode(allocator, source, b.right);
        },
        .logical => |l| {
            try normalizePrivateInNode(allocator, source, l.left);
            try normalizePrivateInNode(allocator, source, l.right);
        },
        .assignment => |a| {
            try normalizePrivateInNode(allocator, source, a.target);
            try normalizePrivateInNode(allocator, source, a.value);
        },
        .conditional => |c| {
            try normalizePrivateInNode(allocator, source, c.test_expr);
            try normalizePrivateInNode(allocator, source, c.consequent);
            try normalizePrivateInNode(allocator, source, c.alternate);
        },
        .sequence => |items| for (items) |e| try normalizePrivateInNode(allocator, source, e),
        .call => |c| {
            try normalizePrivateInNode(allocator, source, c.callee);
            for (c.args) |a| try normalizePrivateInNode(allocator, source, a);
        },
        .new_expr => |n| {
            try normalizePrivateInNode(allocator, source, n.callee);
            if (n.args) |args| for (args) |a| try normalizePrivateInNode(allocator, source, a);
        },
        .member => |m| {
            try normalizePrivateInNode(allocator, source, m.object);
            try normalizePrivateInNode(allocator, source, m.property);
        },
        .function_like => |ptr| try normalizePrivateInFunction(allocator, source, zfunctions.asFunctionNode(ptr)),
        .class_like => |ptr| try normalizePrivateInClass(allocator, source, zfunctions.asClassNode(ptr)),
        .yield_expr => |y| if (y.argument) |a| try normalizePrivateInNode(allocator, source, a),
        .number_literal, .bigint_literal, .string_literal, .boolean_literal, .null_literal, .regex_literal, .this_expr, .super_expr, .new_target => {},
    }
}

/// The object that actually stores a receiver's private members:
/// the object itself, or a function's statics bag (`C.#staticField`).
/// Null for primitives (they can never carry a brand).
pub fn privateHolder(self: *Interpreter, obj: JSValue) !?JSValue {
    return switch (obj.unpack()) {
        .object => obj,
        .function => try self.functionStatics(obj),
        .typed_array, .array_buffer, .data_view => try self.extraPropsObject(obj),
        else => null,
    };
}

fn classDeclaresPrivate(cctx: *const ClassCtx, bare: []const u8) bool {
    for (cctx.private_names) |pn| {
        if (std.mem.eql(u8, pn, bare)) return true;
    }
    return false;
}

fn resolvePrivateCtxForName(env: *Environment, name: []const u8) ?*anyopaque {
    const bare = if (name.len > 0 and name[0] == '#') name[1..] else name;
    const start_ptr = env.resolvePrivateCtx() orelse return null;
    var cur: ?*ClassCtx = interpreter_mod.classCtxFromOpaque(start_ptr);
    while (cur) |cctx| : (cur = cctx.outer_private_ctx) {
        if (classDeclaresPrivate(cctx, bare)) return cctx;
    }
    return start_ptr;
}

pub fn privateGet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!JSValue {
    const ctx = resolvePrivateCtxForName(env, name) orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse
        return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
    // Own->chain record walk with accessor dispatch (instance fields
    // are own props; private methods/accessors live on the prototype).
    var current: ?*const @TypeOf(holder.asObject().value) = &holder.asObject().value;
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const g = rec.getter orelse
                return self.throwError(.type_error, "'{s}' was defined without a getter", .{name});
            return try g.asFunction().value.call(g.asFunction().value.ctx, self.gc_allocator, obj, &.{});
        }
        return rec.value.retain();
    }
    return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
}

pub fn privateSet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8, value: JSValue) anyerror!void {
    const ctx = resolvePrivateCtxForName(env, name) orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse
        return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
    const hv = &holder.asObject().value;
    if (hv.getOwnRecord(key)) |rec| {
        if (rec.isAccessor()) {
            const s = rec.setter orelse
                return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
            _ = try s.asFunction().value.call(s.asFunction().value.ctx, self.gc_allocator, obj, &.{value});
            return;
        }
        // A brand-checked private FIELD write updates in place.
        hv.set(key, value.retain()) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // reserved keys are never frozen/sealed
        };
        return;
    }
    // Chain walk: a prototype hit is an accessor (setter dispatch) or a
    // private METHOD (not writable, spec TypeError).
    var current = hv.getPrototype();
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const s = rec.setter orelse
                return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
            _ = try s.asFunction().value.call(s.asFunction().value.ctx, self.gc_allocator, obj, &.{value});
            return;
        }
        return self.throwError(.type_error, "Cannot assign to private method {s}", .{name});
    }
    return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
}

/// `#name in obj` -- true iff obj carries this class's brand for the
/// name (an own-or-prototype private entry under the encoded key).
pub fn privateHas(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!bool {
    const ctx = resolvePrivateCtxForName(env, name) orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse return false;
    var current: ?*const @TypeOf(holder.asObject().value) = &holder.asObject().value;
    while (current) |o| : (current = o.getPrototype()) {
        if (o.getOwnRecord(key) != null) return true;
    }
    return false;
}

/// Runs a class's instance-field initializers against a fresh instance
/// (this = the instance, private names resolvable, `super.x` usable).
/// Called at constructor entry for base classes and right after
/// `super()` returns for derived ones.
pub fn runInstanceFields(self: *Interpreter, cctx: *ClassCtx, instance: JSValue) anyerror!void {
    if (cctx.instance_fields.len == 0) return;
    if (!instance.isObject() and !instance.isTypedArray() and !instance.isArrayBuffer() and !instance.isDataView() and !instance.isArray()) return; // exotic `this` -- nothing to define on
    const field_env = try self.gcChildEnv(cctx.closure_env);
    field_env.this_value = instance.retain();
    if (cctx.super_proto) |sp|
        field_env.super_proto = sp.retain()
    else if (self.protos.object.isObject())
        field_env.super_proto = self.protos.object.retain();
    field_env.private_ctx = cctx;
    field_env.in_field_initializer = true;
    field_env.new_target = JSValue.UNDEFINED;
    const field_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = true, .configurable = true };
    for (cctx.instance_fields) |fd| {
        const v = if (fd.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
        {
            errdefer v.deinit();
            if (fd.value) |vexpr| try self.maybeNameAnonymousValue(vexpr, v, fieldDisplayName(fd.key));
        }
        const is_private = fd.key.len > 0 and fd.key[0] == 0;
        const target_obj = blk: {
            errdefer v.deinit();
            break :blk if (instance.isObject())
                instance
            else if (instance.isArray())
                try self.arrayPropsObject(instance)
            else
                try self.extraPropsObject(instance);
        };
        if (is_private) {
            const target = &target_obj.asObject().value;
            const saved_frozen = target.is_frozen;
            const saved_ext = target.is_extensible;
            target.is_frozen = false;
            target.is_extensible = true;
            defer {
                target.is_frozen = saved_frozen;
                target.is_extensible = saved_ext;
            }
            try target_obj.objectDefine(fd.key, v, field_attrs);
        } else {
            target_obj.objectDefine(fd.key, v, field_attrs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable, error.PropertyNotConfigurable => return self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{fd.key}),
                else => return err,
            };
        }
    }
}

/// ECMA-262 15.7 ClassDefinitionEvaluation, narrowed: a constructable
/// function (classConstructorCall) whose prototype object holds the
/// instance methods/accessors and chains to the parent's prototype;
/// statics live in the function's bag, chained to the parent's bag
/// (static inheritance). Fields (public/private/static), private
/// methods/accessors, computed keys, and static blocks all supported;
/// still no new.target/decorators -- see README.
pub fn evalClass(self: *Interpreter, env: *Environment, cnode: *zfunctions.ClassNode) anyerror!JSValue {
    const arena = self.gc_allocator;

    var super_ctor: ?JSValue = null;
    // Owned (evalExpression's): ClassCtx retains its own copy below.
    defer if (super_ctor) |sc| sc.deinit();
    var super_proto: ?JSValue = null;
    if (cnode.superclass) |sc_expr| {
        const sc = try self.evalExpression(env, sc_expr);
        if (!sc.isFunction() or !sc.asFunction().value.constructable) {
            defer sc.deinit();
            const shown = try coercion.toDisplayString(arena, sc);
            defer arena.free(shown);
            return self.throwError(.type_error, "Class extends value {s} is not a constructor or null", .{shown});
        }
        super_ctor = sc;
        const parent_proto = try self.getProperty(sc, "prototype");
        defer parent_proto.deinit();
        if (!parent_proto.isObject()) {
            return self.throwError(.type_error, "Class extends value does not have a valid prototype property", .{});
        }
        super_proto = parent_proto;
    }

    // Named classes can self-reference inside method bodies (same
    // wrapper-env trick as named function expressions).
    const closure_env = if (cnode.name != null) try self.gcChildEnv(env) else env;

    var proto = try self.gcNewObject();
    // The parent's prototype/statics are held by this class's own
    // references, not only by the ClassCtx (which only the collector frees).
    if (super_proto) |sp|
        try self.setOwnedPrototype(proto, sp)
    else if (self.protos.object.isObject())
        try proto.asObject().value.setPrototype(&self.protos.object.asObject().value);

    var ctor_fnode: ?*zfunctions.FunctionNode = null;
    for (cnode.elements) |el| {
        if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) {
            ctor_fnode = el.function;
        }
    }

    var private_names_list: std.ArrayList([]const u8) = .empty;
    for (cnode.elements) |el| {
        if (el.key == .private) {
            const raw = el.key.private;
            const bare = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;
            var dup = false;
            for (private_names_list.items) |existing| {
                if (std.mem.eql(u8, existing, bare)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try private_names_list.append(self.arena_state.allocator(), try self.arena_state.allocator().dupe(u8, bare));
        }
    }
    const outer_private_ctx: ?*ClassCtx = if (env.resolvePrivateCtx()) |p| interpreter_mod.classCtxFromOpaque(p) else null;

    const cctx = try arena.create(ClassCtx);
    const class_src_text: ?[]const u8 = if (self.current_source) |s|
        if (cnode.end <= s.len and cnode.start <= cnode.end) s[cnode.start..cnode.end] else null
    else
        null;
    cctx.* = .{
        .interp = self,
        .ctor_fnode = ctor_fnode,
        .closure_env = closure_env,
        .name = cnode.name orelse "",
        .super_ctor = if (super_ctor) |sc| sc.retain() else null,
        .super_proto = if (super_proto) |sp| sp.retain() else null,
        .private_names = private_names_list.items,
        .outer_private_ctx = outer_private_ctx,
        .source_text = class_src_text,
    };
    try self.gcTrackClassCtx(cctx);
    const class_fn = try self.gcNewFunction(.{
        .ctx = cctx,
        .name = cnode.name orelse "",
        .arity = if (ctor_fnode) |f| expectedArgumentCount(f.params) else 0,
        .call = classConstructorCall,
        .constructable = true,
    });
    // Real spec (MakeConstructor): `constructor` is installed with
    // [[Enumerable]]: false, same as every class method/accessor below.
    try proto.asObject().value.defineProperty("constructor", class_fn.retain(), .{ .writable = true, .enumerable = false, .configurable = true });
    class_fn.asFunction().value.prototype = proto;

    // A derived class always gets a statics bag chained to the
    // parent's (forcing the parent's into existence) so static
    // inheritance works even when this class declares no statics.
    if (super_ctor) |parent| {
        const parent_bag = try self.functionStatics(parent);
        const bag = try self.functionStatics(class_fn);
        try self.setOwnedPrototype(bag, parent_bag);
    }

    // The class's own name binds BEFORE static elements run (spec:
    // ClassDefinitionEvaluation initializes the inner binding before
    // static fields/blocks execute, so `static { C.x = 1 }` works).
    // immutable-bindings.md: this binds ONLY the class's internal
    // self-reference (visible inside the class body) as immutable --
    // NOT the outer binding a `class C {}` DECLARATION creates in the
    // enclosing scope (interpreter_stmt.zig's `.class_declaration`
    // case, untouched): confirmed against Node that `class C {} C =
    // 5;` does NOT throw (IsConstantDeclaration is false for
    // ClassDeclaration), only the inner self-reference does.
    if (cnode.name) |n| {
        try closure_env.define(arena, n, class_fn.retain());
        try closure_env.markConst(arena, n);
    }

    // One pass, in declaration order (the spec's order matters for
    // computed-key evaluation, static field initializers, and static
    // blocks, which all run interleaved right here).
    const inst_super_proto: ?JSValue = if (super_proto) |sp| sp else if (self.protos.object.isObject()) self.protos.object else null;
    const static_super_proto: ?JSValue = if (super_ctor) |sc| sc else if (self.protos.function.isObject()) self.protos.function else null;
    const field_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = true, .configurable = true };

    var instance_fields: std.ArrayList(FieldDef) = .empty;
    for (cnode.elements) |el| {
        if (el.kind == .static_block) {
            const sb_env = try self.gcChildEnv(closure_env);
            sb_env.this_value = class_fn.retain();
            if (static_super_proto) |sp| sb_env.super_proto = sp.retain();
            sb_env.private_ctx = cctx;
            sb_env.in_field_initializer = true;
            sb_env.new_target = JSValue.UNDEFINED;
            const fn_node = el.function.?;
            switch (fn_node.body) {
                .block => |b| {
                    const comp = try self.evalBody(sb_env, b.data.block);
                    comp.value.deinit();
                },
                .expression => |e| {
                    const v = try self.evalExpression(sb_env, e);
                    v.deinit();
                },
            }
            continue;
        }

        // Computed/private keys are temporary; property storage copies them.
        const key: []const u8 = switch (el.key) {
            .ident => |n| n,
            .private => |n| try self.encodePrivateKey(cctx, n),
            .computed => |expr| blk: {
                const kv = try self.evalExpression(closure_env, expr);
                defer kv.deinit();
                break :blk try self.encodeKey(kv);
            },
        };
        defer switch (el.key) {
            .ident => {},
            .private, .computed => self.gc_allocator.free(key),
        };

        if (el.is_static and std.mem.eql(u8, key, "prototype")) {
            return self.throwError(.type_error, "Classes may not have a static property named 'prototype'", .{});
        }

        if (el.kind == .field) {
            if (el.is_static) {
                const field_env = try self.gcChildEnv(closure_env);
                field_env.this_value = class_fn.retain();
                if (static_super_proto) |sp| field_env.super_proto = sp.retain();
                field_env.private_ctx = cctx;
                field_env.in_field_initializer = true;
                const v = if (el.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
                const bag = blk: {
                    errdefer v.deinit();
                    if (el.value) |vexpr| try self.maybeNameAnonymousValue(vexpr, v, fieldDisplayName(key));
                    break :blk try self.functionStatics(class_fn);
                };
                try bag.objectDefine(key, v, field_attrs);
            } else {
                try instance_fields.append(arena, .{ .key = try self.arena_state.allocator().dupe(u8, key), .value = el.value });
            }
            continue;
        }

        // Methods / accessors.
        if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) continue;
        const m_super = if (el.is_static) static_super_proto else inst_super_proto;
        const m = try self.makeMethodClosure(closure_env, el.function.?, m_super, cctx);
        const target = if (el.is_static) try self.functionStatics(class_fn) else proto;
        // Real spec (ClassDefinitionEvaluation/PropertyDefinitionEvaluation
        // for MethodDefinition): every class method/accessor is installed
        // via DefinePropertyOrThrow with [[Enumerable]]: false --
        // `target.object.value.set`/`defineAccessor`'s own defaults
        // (Property.init: enumerable true, matching a plain object
        // literal) are wrong here. Regular methods get an explicit
        // descriptor directly; accessors go through defineAccessor
        // first (so a separate `get x(){}`/`set x(v){}` pair still
        // merges into ONE property, its own documented behavior) then
        // have their descriptor corrected the same way
        // definePropertyFromJs already does for JS-level accessors.
        const method_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
        switch (el.kind) {
            .method => {
                try setFunctionName(self, m, key, null);
                try target.objectDefine(key, m, method_attrs);
            },
            .get => {
                try setFunctionName(self, m, key, "get");
                try target.asObject().value.defineAccessor(key, m, null, JSValue.UNDEFINED);
                const rec = target.asObject().value.getOwnRecordMut(key).?;
                rec.descriptor.enumerable = false;
                rec.descriptor.configurable = true;
            },
            .set => {
                try setFunctionName(self, m, key, "set");
                try target.asObject().value.defineAccessor(key, null, m, JSValue.UNDEFINED);
                const rec = target.asObject().value.getOwnRecordMut(key).?;
                rec.descriptor.enumerable = false;
                rec.descriptor.configurable = true;
            },
            .field, .static_block => unreachable,
        }
    }
    cctx.instance_fields = try instance_fields.toOwnedSlice(arena);
    return class_fn;
}

pub fn getOrCompileBytecode(self: *Interpreter, fnode: *const zfunctions.FunctionNode) ?*bytecode_emitter.CompiledCodeBlock {
    if (self.compiled_bytecode.get(fnode)) |cached| {
        return cached;
    }
    const compiled = bytecode_emitter.BytecodeEmitter.emit(self.gc_allocator, fnode) catch |err| switch (err) {
        error.UnsupportedSyntax, error.UnknownLocal => {
            self.compiled_bytecode.put(self.gc_allocator, fnode, null) catch {};
            return null;
        },
        else => return null,
    };
    const cb = self.gc_allocator.create(bytecode_emitter.CompiledCodeBlock) catch return null;
    cb.* = compiled;
    if (self.strict_mode) cb.block.flags.is_strict = true;
    if (self.compile_options.disasm) {
        const text = bytecode_emitter.disassemble(self.gc_allocator, &cb.block) catch null;
        if (text) |t| {
            defer self.gc_allocator.free(t);
            _ = self.console_error_writer.writeAll(t) catch {};
        }
    }
    self.compiled_bytecode.put(self.gc_allocator, fnode, cb) catch {};
    return cb;
}

pub fn prepareCallEnv(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    allocator: Allocator,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    super_ctor: ?JSValue,
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    home_object: ?JSValue,
    force_escaping: bool,
) anyerror!*Environment {
    const escaping = force_escaping or functionMayEscape(fnode);
    const call_env = if (escaping)
        try self.gcChildEnv(closure_env)
    else
        try closure_env.child(self.gc_allocator);
    call_env.escaping = escaping;
    errdefer if (!call_env.escaping) {
        call_env.destroy(self.gc_allocator);
    };
    if (this_value) |tv| {
        call_env.this_value = tv.retain();
        call_env.new_target = (self.pending_call_new_target orelse JSValue.UNDEFINED).retain();
    }
    if (super_proto) |sp| call_env.super_proto = sp.retain();
    if (super_ctor) |sc| call_env.super_ctor = sc.retain();
    call_env.private_ctx = private_ctx;
    if (home_object) |ho| call_env.home_object = ho.retain();

    if (functionNeedsArguments(self, fnode)) {
        var arguments = try self.gcNewArray();
        for (args) |a| _ = try arguments.asArray().value.push(a.retain());
        try self.arguments_arrays.put(self.gc_allocator, @intFromPtr(arguments.asArray()), {});
        if (self.throw_type_error) |tte| {
            const bag = self.array_props.get(@intFromPtr(arguments.asArray())) orelse blk: {
                const b = try self.gcNewObject();
                try self.array_props.put(self.gc_allocator, @intFromPtr(arguments.asArray()), b);
                break :blk b;
            };
            try bag.asObject().value.defineAccessor("callee", tte.retain(), tte.retain(), JSValue.UNDEFINED);
            if (bag.asObject().value.getOwnRecordMut("callee")) |rec| {
                rec.descriptor.enumerable = false;
                rec.descriptor.configurable = false;
            }
        }
        try call_env.define(allocator, "arguments", arguments);
    } else if (fnode.kind != .arrow) {
        try call_env.retainLazyArguments(allocator, args);
    }

    for (fnode.params.items) |param| {
        try markParamPatternTDZ(call_env, allocator, param.pattern);
    }
    if (fnode.params.rest) |rest| {
        try markParamPatternTDZ(call_env, allocator, rest);
    }

    for (fnode.params.items, 0..) |param, i| {
        var value = if (i < args.len) args[i] else JSValue.UNDEFINED;
        // `args[i]` is borrowed; a default is owned (evalExpression's)
        // and bindPattern retains what it binds, so only a default is
        // released here.
        var from_default = false;
        defer if (from_default) value.deinit();
        if (value.isUndefined()) {
            if (param.default) |def| {
                value = try self.evalExpression(call_env, def);
                from_default = true;
                // NamedEvaluation: `function f(x = AnonFn)` names it "x".
                if (param.pattern.* == .identifier) {
                    try self.maybeNameAnonymousValue(def, value, param.pattern.identifier.name);
                }
            }
        }
        try self.bindPattern(call_env, param.pattern, value, .define);
    }
    if (fnode.params.rest) |rest| {
        var rest_arr = try self.gcNewArray();
        // bindPattern retains what it binds.
        defer rest_arr.deinit();
        const start = fnode.params.items.len;
        if (start < args.len) {
            for (args[start..]) |a| _ = try rest_arr.asArray().value.push(a.retain());
        }
        try self.bindPattern(call_env, rest, rest_arr, .define);
    }
    return call_env;
}

pub fn evalPreparedFunctionBody(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    call_env: *Environment,
) anyerror!JSValue {
    switch (fnode.body) {
        .block => |body_stmt| {
            const c = try self.evalBody(call_env, body_stmt.data.block);
            if (c.type == .return_completion) return c.value;
            return JSValue.UNDEFINED;
        },
        .expression => |expr| return try self.evalExpression(call_env, expr),
    }
}

/// The shared body of every user-code invocation: fresh call env off the
/// closure env, this/super bindings, parameter binding (defaults, rest,
/// destructuring via bindPattern), then the body. `this_value` null =
/// don't bind (arrows -- resolveThis walks up instead).
pub fn invokeFunctionNode(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    allocator: Allocator,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    super_ctor: ?JSValue,
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    home_object: ?JSValue,
) anyerror!JSValue {
    if (self.compile_options.use_bytecode_vm and private_ctx == null and super_proto == null and super_ctor == null and home_object == null and closure_env.resolvePrivateCtx() == null) {
        // Unsupported AST shapes have no CodeBlock and stay on the existing
        // walker. The VM is selected only after a CodeBlock was emitted.
        if (getOrCompileBytecode(self, fnode)) |cb| {
            var resolved_this = false;
            const actual_this = if (this_value) |tv| tv else blk: {
                resolved_this = true;
                break :blk closure_env.resolveThis();
            };
            defer if (resolved_this) actual_this.deinit();
            const vm_result = bytecode_vm.vmCall(self.gc_allocator, &cb.block, closure_env, actual_this, args, self) catch |err| switch (err) {
                error.UnsupportedOpcode => return err,
                else => return err,
            };
            return vm_result;
        }
    }
    const call_env = try prepareCallEnv(self, fnode, closure_env, allocator, this_value, super_proto, super_ctor, private_ctx, args, home_object, false);
    defer if (!call_env.escaping) {
        call_env.destroy(self.gc_allocator);
    };
    return evalPreparedFunctionBody(self, fnode, call_env);
}

pub fn closureCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const closure_ctx: *ClosureCtx = @ptrCast(@alignCast(ctx));
    const prev_source = closure_ctx.interp.current_source;
    if (closure_ctx.source_full) |sf| closure_ctx.interp.current_source = sf;
    defer closure_ctx.interp.current_source = prev_source;
    const fnode = closure_ctx.function_node;
    // Arrows have no own `this` binding -- passing null makes
    // `resolveThis()` walk up to closure_env's, matching real lexical
    // `this` inheritance.
    const this: ?JSValue = if (fnode.kind != .arrow) this_value else null;
    const prev_nt = closure_ctx.interp.pending_call_new_target;
    if (fnode.kind != .arrow) {
        if (closure_ctx.interp.construct_target == ctx) {
            closure_ctx.interp.construct_target = null;
            closure_ctx.interp.pending_call_new_target = closure_ctx.interp.construct_new_target orelse JSValue.UNDEFINED;
        } else {
            closure_ctx.interp.pending_call_new_target = JSValue.UNDEFINED;
        }
    }
    defer closure_ctx.interp.pending_call_new_target = prev_nt;
    if (fnode.is_generator and fnode.is_async) {
        return closure_ctx.interp.makeAsyncGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.super_proto, closure_ctx.private_ctx, args, closure_ctx.home_object);
    }
    if (fnode.is_generator) {
        return closure_ctx.interp.makeGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.super_proto, closure_ctx.private_ctx, args, closure_ctx.home_object);
    }
    if (fnode.is_async) {
        return closure_ctx.interp.runAsyncFunction(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    return invokeFunctionNode(closure_ctx.interp, fnode, closure_ctx.closure_env, allocator, this, closure_ctx.super_proto, null, closure_ctx.private_ctx, args, closure_ctx.home_object);
}

pub fn classConstructorCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const cctx: *ClassCtx = @ptrCast(@alignCast(ctx));
    const self = cctx.interp;
    if (self.construct_target != ctx) {
        return self.throwError(.type_error, "Class constructor {s} cannot be invoked without 'new'", .{cctx.name});
    }
    // Consume the token: plain calls made inside the constructor body
    // must not look like constructions (evalNew's defer restores it for
    // its own caller either way).
    const ctor_nt = if (self.construct_new_target) |nt| nt.retain() else JSValue.UNDEFINED;
    defer ctor_nt.deinit();
    const prev_nt = self.pending_call_new_target;
    self.pending_call_new_target = ctor_nt;
    defer self.pending_call_new_target = prev_nt;
    self.construct_target = null;

    // Instance fields: a BASE class initializes them before its ctor body
    // (spec: right after this-creation); a DERIVED class defers them until
    // super() returns -- armed here, consumed by evalCall's super() branch
    // (save/restore keeps nested constructions inside the body correct).
    if (cctx.super_ctor == null) {
        try self.runInstanceFields(cctx, this_value);
    }

    if (cctx.ctor_fnode) |fnode| {
        if (cctx.super_ctor != null) {
            const prev_pending = self.pending_field_init;
            const prev_adopted = self.adopted_super_this;
            self.pending_field_init = cctx;
            self.adopted_super_this = null;
            defer {
                self.pending_field_init = prev_pending;
                if (self.adopted_super_this) |value| value.deinit();
                self.adopted_super_this = prev_adopted;
            }
            const result = try invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args, null);
            if (result.isUndefined()) {
                if (self.pending_field_init != null) {
                    return self.throwError(.reference_error, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor", .{});
                }
                if (self.adopted_super_this) |value| return value.retain();
            } else if (!@import("builtin_helpers.zig").isObjectLike(result)) {
                result.deinit();
                return self.throwError(.type_error, "Derived constructors may only return object or undefined", .{});
            }
            return result;
        }
        return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args, null);
    }
    // Implicit constructor: a derived class forwards this + args to its
    // parent (`constructor(...args) { super(...args) }`) and then runs its
    // own field initializers; a base class is a no-op.
    if (cctx.super_ctor) |parent| {
        self.construct_target = parent.asFunction().value.ctx;
        defer self.construct_target = null;
        const parent_result = try parent.asFunction().value.call(parent.asFunction().value.ctx, allocator, this_value, args);
        if ((parent_result.isTemporal() and self.temporal_protos.contains(@intFromPtr(parent_result.asTemporal()))) or parent_result.isTypedArray() or parent_result.isArrayBuffer() or parent_result.isDataView() or parent_result.isSet() or parent_result.isMap() or parent_result.isArray()) {
            errdefer parent_result.deinit();
            if (parent_result.isArray() and this_value.isObject()) {
                if (this_value.asObject().value.getPrototype()) |pp| {
                    const Box = @TypeOf(this_value.asObject().*);
                    const box: *Box = @fieldParentPtr("value", pp);
                    try self.setOwnedPrototype(parent_result, JSValue.fromObject(box));
                }
            }
            try self.runInstanceFields(cctx, parent_result);
            return parent_result;
        }
        // Ordinary parent constructors return the provisional instance (or
        // another non-Temporal value) without transferring ownership here.
        // Keep the old path intact: constructValue retains this_value and
        // returns it after this implicit constructor yields undefined.
        try self.runInstanceFields(cctx, this_value);
    }
    return JSValue.UNDEFINED;
}
