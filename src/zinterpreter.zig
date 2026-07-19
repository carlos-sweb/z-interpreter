const interpreter_mod = @import("interpreter.zig");
const environment_mod = @import("environment.zig");
const completion_mod = @import("completion.zig");

pub const Interpreter = interpreter_mod.Interpreter;
pub const ModuleLoader = interpreter_mod.ModuleLoader;
pub const LoadedModule = interpreter_mod.LoadedModule;
pub const Environment = environment_mod.Environment;
pub const Completion = completion_mod.Completion;
pub const CompletionType = completion_mod.CompletionType;

pub const coercion = @import("coercion.zig");
pub const inspect = @import("inspect.zig");

test {
    _ = @import("environment.zig");
    _ = @import("completion.zig");
    _ = @import("coercion.zig");
    _ = @import("inspect.zig");
    _ = @import("interpreter.zig");
    _ = @import("fiber.zig");
}
