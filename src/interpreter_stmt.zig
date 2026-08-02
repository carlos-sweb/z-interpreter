//! Step 5 Phase C batch 8: the statement/hoisting/loop cluster --
//! evalStatement and its whole family: program/body evaluation, the
//! var/lexical hoisting pre-passes, and while/do-while/for(-in/-of
//! dispatch) loop evaluation. Split out of interpreter.zig; see
//! z-interpreter-refactor.md.

const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zfunctions = @import("zfunctions");

const coercion = @import("coercion.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;

/// Everything a statement can do, flattened into one value: the
/// Completion channel (normal/return/break/continue) and the JsThrow
/// channel. This is the merge point try/finally hangs on.
const Outcome = union(enum) {
    completion: Completion,
    thrown: JSValue,
};

/// Runs a statement, capturing BOTH abrupt channels. Catches ONLY
/// error.JsThrow; OutOfMemory, NotImplemented, etc. propagate
/// untouched (a JS `catch` must never swallow an interpreter feature
/// gap).
pub fn runCapturing(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!Outcome {
    const c = self.evalStatement(env, stmt) catch |err| {
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception orelse unreachable; // raiser invariant
        self.pending_exception = null; // take
        return Outcome{ .thrown = ex };
    };
    return Outcome{ .completion = c };
}

/// Re-delivers an Outcome on its original channel.
pub fn deliver(self: *Interpreter, outcome: Outcome) anyerror!Completion {
    return switch (outcome) {
        .completion => |c| c,
        .thrown => |ex| self.throwValue(ex),
    };
}

/// The raw statement loop -- no hoisting. Callers go through
/// `evalBody` (function/script bodies: var + lexical pre-passes) or
/// `evalStatementList` (blocks: lexical pre-pass only).
pub fn evalProgram(self: *Interpreter, env: *Environment, program: []const *zstatements.Statement) anyerror!Completion {
    var last_value: JSValue = JSValue.UNDEFINED;
    for (program) |stmt| {
        const c = try self.evalStatement(env, stmt);
        if (c.type != .normal) return c;
        last_value = c.value;
    }
    return .{ .type = .normal, .value = last_value };
}

/// Function-body / script entry: `var` names hoist here (defined as
/// undefined unless already present -- parameters win), then the
/// ordinary per-StatementList lexical hoisting runs.
// z-interpreter-refactor.md, Step 5 Phase C batch 3: `pub` since
// interpreter_runtime.zig's run/evalSource/runPendingJob now call it
// across the file boundary.
pub fn evalBody(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!Completion {
    try self.hoistVarScope(env, stmts);
    return self.evalStatementList(env, stmts);
}

/// Every StatementList entry: function declarations become callable
/// immediately, let/const/class names enter their TDZ, then the
/// statements run.
pub fn evalStatementList(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!Completion {
    try self.hoistLexical(env, stmts);
    return self.evalProgram(env, stmts);
}

// ===== Hoisting pre-passes =====

/// Collects every `var`-declared name in a function/script body,
/// recursing through blocks, if arms, loop bodies AND loop heads,
/// switch cases, try/catch/finally, and labelled statements -- but
/// never into nested function or class bodies (their vars are their
/// own). Annex B's sloppy-mode escape of block-level function
/// declarations to function scope is deliberately NOT implemented
/// (this engine is always-strict; see README).
pub fn hoistVarScope(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!void {
    for (stmts) |stmt| try self.hoistVarsInStatement(env, stmt);
}

pub fn hoistVarsInStatement(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!void {
    switch (stmt.data) {
        .variable => |v| if (v.kind == .@"var") {
            for (v.declarators) |decl| try self.hoistVarPattern(env, decl.pattern);
        },
        .block => |stmts| try self.hoistVarScope(env, stmts),
        .if_stmt => |s| {
            try self.hoistVarsInStatement(env, s.consequent);
            if (s.alternate) |alt| try self.hoistVarsInStatement(env, alt);
        },
        .while_stmt => |s| try self.hoistVarsInStatement(env, s.body),
        .do_while => |s| try self.hoistVarsInStatement(env, s.body),
        .for_stmt => |s| {
            switch (s.head) {
                .c_style => |head| if (head.init) |init_clause| {
                    switch (init_clause) {
                        .decl => |d| if (d.kind == .@"var") {
                            for (d.declarators) |decl| try self.hoistVarPattern(env, decl.pattern);
                        },
                        .expr => {},
                    }
                },
                .for_in => |head| try self.hoistVarForBinding(env, head.binding),
                .for_of => |head| try self.hoistVarForBinding(env, head.binding),
            }
            try self.hoistVarsInStatement(env, s.body);
        },
        .labelled => |s| try self.hoistVarsInStatement(env, s.body),
        .try_stmt => |s| {
            try self.hoistVarsInStatement(env, s.block);
            if (s.handler) |h| try self.hoistVarsInStatement(env, h.body);
            if (s.finalizer) |fin| try self.hoistVarsInStatement(env, fin);
        },
        .switch_stmt => |s| for (s.cases) |case| {
            for (case.consequent) |cs| try self.hoistVarsInStatement(env, cs);
        },
        .with_stmt => |s| try self.hoistVarsInStatement(env, s.body),
        // `export var x = ...` must hoist like its bare declaration.
        .export_decl => |e| switch (e) {
            .declaration => |inner| try self.hoistVarsInStatement(env, inner),
            else => {},
        },
        else => {},
    }
}

pub fn hoistVarForBinding(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding) anyerror!void {
    switch (binding) {
        .declared => |d| if (d.kind == .@"var") try self.hoistVarPattern(env, d.pattern),
        .existing, .existing_pattern => {},
    }
}

/// Defines every name a var declarator's pattern binds as undefined,
/// unless this env already has it (parameters, earlier vars).
pub fn hoistVarPattern(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
    const arena = self.gc_allocator;
    switch (pattern.*) {
        .identifier => |id| if (!env.bindings.contains(id.name)) {
            try env.define(arena, id.name, JSValue.UNDEFINED);
            try markGlobalVarName(self, env, id.name);
        },
        .array => |arr| {
            for (arr.elements) |maybe_el| {
                if (maybe_el) |el| try self.hoistVarPattern(env, el.pattern);
            }
            if (arr.rest) |r| try self.hoistVarPattern(env, r);
        },
        .object => |obj| {
            for (obj.properties) |p| try self.hoistVarPattern(env, p.value);
            if (obj.rest) |r| if (!env.bindings.contains(r.name)) {
                try env.define(arena, r.name, JSValue.UNDEFINED);
                try markGlobalVarName(self, env, r.name);
            };
        },
    }
}

/// Records `name` as a real (non-configurable) own property of the
/// global object -- but ONLY when `env` is script_env itself, i.e. this
/// is a genuine top-level `var`/function declaration, not one nested in
/// a function body or block scope (those never reach script_env: blocks
/// get their own child env, and function calls hoist into their own
/// call env). See `global_var_names`'s doc comment for why this can't
/// just be derived from `env.bindings` directly.
fn markGlobalVarName(self: *Interpreter, env: *Environment, name: []const u8) anyerror!void {
    if (self.global_var_env == env) {
        try self.global_var_names.put(self.gc_allocator, name, {});
    }
}

/// The per-StatementList lexical pre-pass, over DIRECT statements
/// only (nested blocks get their own on entry). Function declarations
/// hoist fully (mutual recursion, call-before-declaration);
/// let/const/class names enter the TDZ; duplicate declarations in the
/// same scope are the real "already been declared" SyntaxError
/// (catchable here since this engine has no parse-time scope
/// analysis).
pub fn hoistLexical(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement) anyerror!void {
    const arena = self.gc_allocator;
    for (stmts) |stmt| {
        switch (stmt.data) {
            .function_declaration => |ptr| {
                const fnode = zfunctions.asFunctionNode(ptr);
                const name = fnode.kind.function_decl.name;
                // `let f; function f() {}` is the real SyntaxError;
                // f-over-f or f-over-var stays legal (later wins).
                if (env.tdz.contains(name)) {
                    return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{name});
                }
                const value = try self.makeClosure(env, fnode);
                try env.define(arena, name, value);
                try markGlobalVarName(self, env, name);
            },
            .variable => |v| {
                if (v.kind == .@"var") {
                    // Bindings come from the var pre-pass; here vars
                    // only participate in the redeclaration check
                    // (`let x; var x;` is the real SyntaxError).
                    for (v.declarators) |decl| try self.checkVarNotShadowingLexical(env, decl.pattern);
                    continue;
                }
                for (v.declarators) |decl| try self.markPatternTDZ(env, decl.pattern);
            },
            .class_declaration => |ptr| {
                const cnode = zfunctions.asClassNode(ptr);
                const name = cnode.name.?;
                if (env.declaresLocally(name)) {
                    return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{name});
                }
                try env.markTDZ(arena, name);
            },
            // `export function f() {}` hoists exactly like the bare
            // declaration (call-before-declaration inside the module).
            .export_decl => |e| switch (e) {
                .declaration => |inner| try self.hoistLexical(env, &.{inner}),
                else => {},
            },
            else => {},
        }
    }
}

pub fn markPatternTDZ(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
    const arena = self.gc_allocator;
    switch (pattern.*) {
        .identifier => |id| {
            if (env.declaresLocally(id.name)) {
                return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{id.name});
            }
            try env.markTDZ(arena, id.name);
        },
        .array => |arr| {
            for (arr.elements) |maybe_el| {
                if (maybe_el) |el| try self.markPatternTDZ(env, el.pattern);
            }
            if (arr.rest) |r| try self.markPatternTDZ(env, r);
        },
        .object => |obj| {
            for (obj.properties) |p| try self.markPatternTDZ(env, p.value);
            if (obj.rest) |r| {
                if (env.declaresLocally(r.name)) {
                    return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{r.name});
                }
                try env.markTDZ(arena, r.name);
            }
        },
    }
}

pub fn checkVarNotShadowingLexical(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern) anyerror!void {
    switch (pattern.*) {
        .identifier => |id| if (env.tdz.contains(id.name)) {
            return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{id.name});
        },
        .array => |arr| {
            for (arr.elements) |maybe_el| {
                if (maybe_el) |el| try self.checkVarNotShadowingLexical(env, el.pattern);
            }
            if (arr.rest) |r| try self.checkVarNotShadowingLexical(env, r);
        },
        .object => |obj| {
            for (obj.properties) |p| try self.checkVarNotShadowingLexical(env, p.value);
            if (obj.rest) |r| if (env.tdz.contains(r.name)) {
                return self.throwError(.syntax_error, "Identifier '{s}' has already been declared", .{r.name});
            };
        },
    }
}

// ===== Statements =====

pub fn evalStatement(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!Completion {
    const arena = self.gc_allocator;
    switch (stmt.data) {
        .empty, .debugger => return .{},
        .expr_stmt => |expr| {
            const v = try self.evalExpression(env, expr);
            return .{ .type = .normal, .value = v };
        },
        .block => |stmts| {
            const block_env = try self.gcChildEnv(env);
            return self.evalStatementList(block_env, stmts);
        },
        .variable => |v| {
            for (v.declarators) |decl| {
                // An initializer-less `var a;` is a no-op at execution
                // time -- the hoist pre-pass already created the
                // binding, and real JS does NOT reset an existing
                // value (`function h(a) { var a; return a; }` keeps
                // the argument).
                if (v.kind == .@"var" and decl.init == null) continue;
                const value = if (decl.init) |init_expr| try self.evalExpression(env, init_expr) else JSValue.UNDEFINED;
                // NamedEvaluation: `let/const/var x = AnonFn` names the
                // function/class "x" -- simple-identifier targets only.
                if (decl.init) |init_expr| {
                    if (decl.pattern.* == .identifier) {
                        try self.maybeNameAnonymousValue(init_expr, value, decl.pattern.identifier.name);
                    }
                }
                // var writes to its hoisted function-scope binding
                // (that's how `if (1) { var x = 5; } x` works);
                // let/const define here, ending their TDZ.
                try self.bindPattern(env, decl.pattern, value, if (v.kind == .@"var") .assign else .define);
            }
            return .{};
        },
        .if_stmt => |s| {
            const test_v = try self.evalExpression(env, s.test_expr);
            if (coercion.isTruthy(test_v)) return self.evalStatement(env, s.consequent);
            if (s.alternate) |alt| return self.evalStatement(env, alt);
            return .{};
        },
        .while_stmt => |s| return self.evalWhile(env, s, &.{}),
        .do_while => |s| return self.evalDoWhile(env, s, &.{}),
        .for_stmt => |s| return self.evalForStatement(env, s, &.{}),
        .return_stmt => |arg| {
            const v = if (arg) |e| try self.evalExpression(env, e) else JSValue.UNDEFINED;
            return .{ .type = .return_completion, .value = v };
        },
        // Label validity (label exists, continue targets a loop) was
        // already guaranteed at parse time by z-statements
        // (UndefinedLabel/IllegalContinue), so the runtime can trust
        // every target resolves to some enclosing labelled statement.
        .break_stmt => |label| return .{ .type = .break_completion, .target = label },
        .continue_stmt => |label| return .{ .type = .continue_completion, .target = label },
        // ECMA-262 14.13.4 LabelledEvaluation: collect the whole label
        // chain (`a: b: for (...)` attaches BOTH labels to the loop)
        // and hand it to the loop as its label set; for non-loop
        // bodies, a matching labelled break converts to normal here.
        .labelled => |s| {
            var labels: std.ArrayList([]const u8) = .empty;
            defer labels.deinit(arena);
            try labels.append(arena, s.label);
            var inner = s.body;
            while (inner.data == .labelled) {
                try labels.append(arena, inner.data.labelled.label);
                inner = inner.data.labelled.body;
            }
            const c = switch (inner.data) {
                .while_stmt => |w| try self.evalWhile(env, w, labels.items),
                .do_while => |d| try self.evalDoWhile(env, d, labels.items),
                .for_stmt => |f| try self.evalForStatement(env, f, labels.items),
                else => try self.evalStatement(env, inner),
            };
            if (c.type == .break_completion) {
                if (c.target) |t| {
                    if (labelIn(t, labels.items)) return .{ .type = .normal, .value = c.value };
                }
            }
            return c;
        },
        .function_declaration => |ptr| {
            const fnode = zfunctions.asFunctionNode(ptr);
            const value = try self.makeClosure(env, fnode);
            const name = switch (fnode.kind) {
                .function_decl => |d| d.name,
                else => unreachable, // z-functions always produces .function_decl at statement position
            };
            try env.define(arena, name, value);
            return .{};
        },
        .class_declaration => |ptr| {
            const cnode = zfunctions.asClassNode(ptr);
            const value = try self.evalClass(env, cnode);
            // Declarations always carry a name (MissingClassName is a
            // parse error otherwise).
            try env.define(arena, cnode.name.?, value.retain());
            return .{};
        },
        // Reaching these through evalStatement means they're NOT at a
        // module's top level (evalModuleBody intercepts those) -- a
        // classic script, or nested in a block. Real JS rejects both
        // at parse time; ours is a catchable runtime error.
        .import_decl => return self.throwError(.syntax_error, "Cannot use import statement outside a module", .{}),
        .export_decl => return self.throwError(.syntax_error, "Unexpected token 'export'", .{}),
        .throw_stmt => |arg| {
            // The `try` on the argument is load-bearing: `throw f()`
            // where f itself throws must propagate f's exception.
            const v = try self.evalExpression(env, arg);
            return self.throwValue(v);
        },
        // ECMA-262 14.15.3 TryStatement evaluation. h.body/s.block/
        // s.finalizer are always `.block` statements, so the existing
        // `.block` arm supplies each fresh scope (the catch_env holding
        // the param becomes its parent -- spec-correct nesting for
        // free). Completion.target rides along inside
        // Outcome.completion untouched, so future labelled-break
        // support changes nothing here.
        .try_stmt => |s| {
            var result = try self.runCapturing(env, s.block);

            if (result == .thrown and s.handler != null) {
                const h = s.handler.?;
                const catch_env = try self.gcChildEnv(env);
                if (h.param) |p| try self.bindPattern(catch_env, p, result.thrown, .define);
                // A throw from the catch body becomes the new .thrown
                // result; the original exception is dropped
                // (spec-correct).
                result = try self.runCapturing(catch_env, h.body);
            }

            // The finalizer runs on EVERY path (normal, caught,
            // uncaught-throw, return/break/continue). Its result
            // overrides iff it is abrupt: `try { return 1 } finally
            // { return 2 }` is 2, and a finally-throw drops the
            // original exception. A *normal* finally keeps `result`
            // INCLUDING its value: `try { 1 } finally { 2 }` is 1.
            if (s.finalizer) |fin| {
                const fin_outcome = try self.runCapturing(env, fin);
                switch (fin_outcome) {
                    .completion => |fc| if (fc.type != .normal) {
                        result = fin_outcome;
                    },
                    .thrown => result = fin_outcome,
                }
            }

            return try self.deliver(result);
        },
        // ECMA-262 14.12 CaseBlockEvaluation. The AST's flat case order
        // is already "A clauses, default, B clauses", so one selector
        // scan (skipping default) equals the spec's A-then-B search
        // order, and executing from the chosen index to the end gives
        // natural fallthrough -- INCLUDING the default's statements
        // when the match came before it (real JS semantics).
        .switch_stmt => |s| {
            const disc = try self.evalExpression(env, s.discriminant); // evaluated ONCE
            // The whole CaseBlock is ONE lexical scope (a let in one
            // case is visible in later ones -- real JS quirk), so the
            // lexical pre-pass runs over every case's consequent
            // before any selector/statement evaluates.
            const switch_env = try self.gcChildEnv(env);
            for (s.cases) |case| try self.hoistLexical(switch_env, case.consequent);

            var start_index: ?usize = null;
            for (s.cases, 0..) |case, i| {
                const t = case.test_expr orelse continue;
                const v = try self.evalExpression(switch_env, t);
                if (zvalue.equality.strictEquals(disc, v)) {
                    start_index = i;
                    break;
                }
            }
            if (start_index == null) {
                for (s.cases, 0..) |case, i| {
                    if (case.test_expr == null) {
                        start_index = i;
                        break;
                    }
                }
            }

            var last_value: JSValue = JSValue.UNDEFINED;
            if (start_index) |start| {
                for (s.cases[start..]) |case| {
                    for (case.consequent) |case_stmt| {
                        const c = try self.evalStatement(switch_env, case_stmt);
                        switch (c.type) {
                            .normal => last_value = c.value,
                            .break_completion => {
                                if (c.target == null) return .{ .type = .normal, .value = last_value };
                                return c; // labelled break: handled by the labelled wrapper/loop
                            },
                            .return_completion, .continue_completion => return c,
                        }
                    }
                }
            }
            return .{ .type = .normal, .value = last_value };
        },
        .with_stmt => return error.NotImplemented,
    }
}

// ===== Loops (each takes the labelSet attached by any enclosing
// labelled statement -- ECMA-262's labelSet parameter; empty for a
// plain unlabelled loop) =====

/// Decides whether this loop owns an abrupt break/continue: unlabelled
/// ones always belong to the nearest enclosing loop; labelled ones only
/// if the target is in this loop's label set.
pub fn loopOwns(target: ?[]const u8, labels: []const []const u8) bool {
    const t = target orelse return true;
    return labelIn(t, labels);
}

pub fn evalWhile(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
    while (coercion.isTruthy(try self.evalExpression(env, s.test_expr))) {
        const c = try self.evalStatement(env, s.body);
        switch (c.type) {
            .break_completion => {
                if (loopOwns(c.target, labels)) break;
                return c;
            },
            .continue_completion => {
                if (!loopOwns(c.target, labels)) return c;
            },
            .return_completion => return c,
            .normal => {},
        }
    }
    return .{};
}

pub fn evalDoWhile(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
    while (true) {
        const c = try self.evalStatement(env, s.body);
        switch (c.type) {
            .break_completion => {
                if (loopOwns(c.target, labels)) break;
                return c;
            },
            .continue_completion => {
                if (!loopOwns(c.target, labels)) return c;
            },
            .return_completion => return c,
            .normal => {},
        }
        if (!coercion.isTruthy(try self.evalExpression(env, s.test_expr))) break;
    }
    return .{};
}

pub fn evalForStatement(self: *Interpreter, env: *Environment, s: anytype, labels: []const []const u8) anyerror!Completion {
    switch (s.head) {
        .c_style => |head| {
            const loop_env = try self.gcChildEnv(env);
            if (head.init) |init_clause| {
                switch (init_clause) {
                    .decl => |d| {
                        for (d.declarators) |decl| {
                            // Same no-op rule as the .variable arm:
                            // `for (var i; ...)` must not reset a
                            // hoisted binding.
                            if (d.kind == .@"var" and decl.init == null) continue;
                            const value = if (decl.init) |e| try self.evalExpression(loop_env, e) else JSValue.UNDEFINED;
                            try self.bindPattern(loop_env, decl.pattern, value, if (d.kind == .@"var") .assign else .define);
                        }
                    },
                    .expr => |e| _ = try self.evalExpression(loop_env, e),
                }
            }
            while (true) {
                if (head.test_expr) |t| {
                    if (!coercion.isTruthy(try self.evalExpression(loop_env, t))) break;
                }
                const c = try self.evalStatement(loop_env, s.body);
                switch (c.type) {
                    .break_completion => {
                        if (loopOwns(c.target, labels)) break;
                        return c;
                    },
                    .continue_completion => {
                        if (!loopOwns(c.target, labels)) return c;
                    },
                    .return_completion => return c,
                    .normal => {},
                }
                if (head.update) |u| _ = try self.evalExpression(loop_env, u);
            }
            return .{};
        },
        .for_in => |head| return self.evalForIn(env, head, s.body, labels),
        .for_of => |head| return self.evalForOf(env, head, s.body, labels),
    }
}

fn labelIn(target: []const u8, labels: []const []const u8) bool {
    for (labels) |l| {
        if (std.mem.eql(u8, l, target)) return true;
    }
    return false;
}

