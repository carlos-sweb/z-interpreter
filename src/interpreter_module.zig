//! Module loading (`import`/`export`): host-provided `ModuleLoader`
//! wiring, the module cache (`ModuleRecord`), and the load/link/evaluate
//! pipeline. No interleaving -- this was already a single self-contained
//! "===== Modules (import/export) =====" section. Every method here is
//! `pub` (batch 1's lesson: `self.foo()` always resolves through
//! whichever file declares the `Interpreter` struct's alias, regardless
//! of where the calling method's body lives -- true even for calls
//! between two methods that moved here together, e.g. `runModule`
//! calling `loadModule`). `runEventLoop`/`hoistLexical`/`hoistVarScope`
//! (still in `interpreter.zig`, not yet extracted) were made `pub`
//! there for this file's sake; `evalStatement`/`evalExpression` were
//! already `pub`. `ModuleRecord` made `pub` in `interpreter.zig` too.
//! z-interpreter-refactor.md, Step 5 Phase C batch 2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;
const ModuleLoader = interpreter_mod.ModuleLoader;
const ModuleRecord = interpreter_mod.ModuleRecord;
const LoadedModule = interpreter_mod.LoadedModule;
const builtins = @import("builtins.zig");

// ===== Modules (import/export) =====

pub fn setModuleLoader(self: *Interpreter, loader: ModuleLoader) void {
    self.module_loader = loader;
}

/// Loads and evaluates a module graph from its entry specifier, then
/// drains the event loop (async-heavy modules behave like run()).
/// The loader must be set first.
pub fn runModule(self: *Interpreter, specifier: []const u8) anyerror!JSValue {
    self.pending_exception = null;
    self.stack_limit = @frameAddress() -| Interpreter.main_stack_budget;
    if (!self.globals_ready) {
        try builtins.setupGlobals(self);
        self.globals_ready = true;
    }
    if (self.script_env == null) self.script_env = try self.gcChildEnv(self.global_env);
    _ = self.loadModule(specifier, null) catch |err| {
        if (err != error.JsThrow) return err;
        return error.UncaughtException;
    };
    self.runEventLoop() catch |err| {
        if (err != error.JsThrow) return err;
        return error.UncaughtException;
    };
    return JSValue.UNDEFINED;
}

/// Resolve + parse + evaluate one module, once (cache by resolved
/// path). Cycles are the documented narrowing: bindings snapshot at
/// the end of a module's evaluation instead of staying live, so a
/// dependency cycle can't be linked -- catchable error instead.
pub fn loadModule(self: *Interpreter, specifier: []const u8, referrer: ?[]const u8) anyerror!*ModuleRecord {
    // AST nodes stay on the arena; the module record/env/exports and
    // everything else this function creates are GC-tracked.
    const ast_arena = self.arena_state.allocator();
    const gc = self.gc_allocator;
    const loader = self.module_loader orelse
        return self.throwError(.syntax_error, "Cannot use import statement outside a module", .{});
    const loaded = (try loader.load(loader.ctx, ast_arena, specifier, referrer)) orelse
        return self.throwError(.generic, "Cannot find module '{s}' imported from {s}", .{ specifier, referrer orelse "<entry>" });
    if (self.modules.get(loaded.path)) |rec| {
        if (rec.state == .loading) {
            return self.throwError(.generic, "Circular dependency detected: '{s}' (live bindings are not supported)", .{loaded.path});
        }
        return rec;
    }
    const rec = try gc.create(ModuleRecord);
    rec.* = .{ .path = loaded.path, .exports = try self.gcNewObject(), .state = .loading };
    try self.modules.put(gc, loaded.path, rec);

    const parser = try zfunctions.Parser.init(ast_arena, loaded.source);
    parser.setStackLimit(self.stack_limit);
    const program = try parser.parseProgram();
    const module_env = try self.gcChildEnv(self.global_env);
    // The entry file (no referrer -- never a dependency reached via
    // `import`) still gets classic-script globalThis semantics: z-run
    // treats every script as a "module" for import/export support, but
    // test262 (and real-world entry scripts) expect top-level `var`/
    // function declarations to reify onto globalThis, exactly like
    // run()'s script_env does. A real dependency module's own top-level
    // `var`s must NOT do this (spec: only classic scripts populate the
    // global object), so this only fires for the untouched initial call.
    if (referrer == null and self.global_var_env == null) {
        self.global_var_env = module_env;
        // Real spec: a Script's top-level `this` is globalThis, but a
        // Module's is always `undefined` (confirmed against real
        // Node's actual .mjs execution -- this engine's prior
        // `this === undefined` for every entry file was only
        // ACCIDENTALLY correct for genuine modules, and wrong for the
        // vast majority of entry files/test262 tests, which are
        // Script-shaped and never use import/export at all).
        // `import`/`export` are reserved words, so their presence as a
        // top-level declaration is the exact, spec-sound signal that a
        // file is a real module (dynamic `import()` is a distinct
        // expression node, not a declaration, and stays legal in a
        // Script either way) -- absence means it should behave like a
        // classic Script instead.
        var has_module_syntax = false;
        for (program) |stmt| {
            if (stmt.data == .import_decl or stmt.data == .export_decl) {
                has_module_syntax = true;
                break;
            }
        }
        if (!has_module_syntax) module_env.this_value = self.global_object;
    }

    // Import pre-pass: dependencies evaluate first (DFS), then their
    // exports bind here -- snapshots, taken after the dep finished.
    for (program) |stmt| {
        if (stmt.data != .import_decl) continue;
        const imp = stmt.data.import_decl;
        const dep = try self.loadModule(imp.source, rec.path);
        if (imp.namespace_local) |ns| {
            try module_env.define(gc, ns, dep.exports.retain());
        }
        if (imp.default_local) |dl| {
            const v = dep.exports.object.value.get("default") orelse
                return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named 'default'", .{imp.source});
            try module_env.define(gc, dl, v.retain());
        }
        for (imp.named) |spec| {
            const v = dep.exports.object.value.get(spec.imported) orelse
                return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named '{s}'", .{ imp.source, spec.imported });
            try module_env.define(gc, spec.local, v.retain());
        }
    }

    try self.evalModuleBody(module_env, program, rec);
    rec.state = .evaluated;
    return rec;
}

/// The module-flavored evalBody: same hoisting (the pre-passes see
/// through `export` wrappers), plus export handling. Exported values
/// are collected AFTER the body runs -- `export { x }` before the
/// declaration works, and an `export let` mutated during evaluation
/// exports its final value.
pub fn evalModuleBody(self: *Interpreter, env: *Environment, stmts: []const *zstatements.Statement, rec: *ModuleRecord) anyerror!void {
    const arena = self.gc_allocator;
    try self.hoistVarScope(env, stmts);
    try self.hoistLexical(env, stmts);

    var decl_names: std.ArrayList([]const u8) = .empty;
    defer decl_names.deinit(arena);
    var local_specs: std.ArrayList(zstatements.ExportSpecifier) = .empty;
    defer local_specs.deinit(arena);

    for (stmts) |stmt| {
        switch (stmt.data) {
            .import_decl => {}, // bound by the pre-pass
            .export_decl => |e| switch (e) {
                .declaration => |inner| {
                    _ = try self.evalStatement(env, inner);
                    try self.collectDeclaredNames(inner, &decl_names);
                },
                .default => |expr| {
                    const v = try self.evalExpression(env, expr);
                    try rec.exports.object.value.set("default", v.retain());
                },
                .named => |n| {
                    if (n.source) |src| {
                        const dep = try self.loadModule(src, rec.path);
                        for (n.specifiers) |spec| {
                            const v = dep.exports.object.value.get(spec.local) orelse
                                return self.throwError(.syntax_error, "The requested module '{s}' does not provide an export named '{s}'", .{ src, spec.local });
                            try rec.exports.object.value.set(spec.exported, v.retain());
                        }
                    } else {
                        for (n.specifiers) |spec| try local_specs.append(arena, spec);
                    }
                },
                .all => |a| {
                    // `export *` re-exports everything EXCEPT default
                    // (the real rule).
                    const dep = try self.loadModule(a.source, rec.path);
                    const keys = try dep.exports.object.value.keys(arena);
                    defer arena.free(keys);
                    for (keys) |k| {
                        if (std.mem.eql(u8, k, "default")) continue;
                        try rec.exports.object.value.set(k, dep.exports.object.value.get(k).?.retain());
                    }
                },
            },
            else => _ = try self.evalStatement(env, stmt),
        }
    }

    for (decl_names.items) |name| {
        const v = env.get(name) orelse continue;
        try rec.exports.object.value.set(name, v.retain());
    }
    for (local_specs.items) |spec| {
        const v = env.get(spec.local) orelse
            return self.throwError(.syntax_error, "Export '{s}' is not defined in module", .{spec.local});
        try rec.exports.object.value.set(spec.exported, v.retain());
    }
}

/// Every name an exported declaration binds: declarator patterns
/// (destructuring included), function and class names.
pub fn collectDeclaredNames(self: *Interpreter, stmt: *zstatements.Statement, list: *std.ArrayList([]const u8)) anyerror!void {
    const arena = self.gc_allocator;
    switch (stmt.data) {
        .variable => |v| for (v.declarators) |d| try self.collectPatternNames(d.pattern, list),
        .function_declaration => |ptr| {
            try list.append(arena, zfunctions.asFunctionNode(ptr).kind.function_decl.name);
        },
        .class_declaration => |ptr| {
            try list.append(arena, zfunctions.asClassNode(ptr).name.?);
        },
        else => {},
    }
}

pub fn collectPatternNames(self: *Interpreter, pattern: *const zstatements.BindingPattern, list: *std.ArrayList([]const u8)) anyerror!void {
    const arena = self.gc_allocator;
    switch (pattern.*) {
        .identifier => |id| try list.append(arena, id.name),
        .array => |arr| {
            for (arr.elements) |maybe_el| {
                if (maybe_el) |el| try self.collectPatternNames(el.pattern, list);
            }
            if (arr.rest) |r| try self.collectPatternNames(r, list);
        },
        .object => |obj| {
            for (obj.properties) |p| try self.collectPatternNames(p.value, list);
            if (obj.rest) |r| try list.append(arena, r.name);
        },
    }
}
