const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const CompletionType = enum {
    normal,
    return_completion,
    break_completion,
    continue_completion,
    // There is deliberately NO throw_completion variant: exceptions must
    // unwind through *expression* evaluation too (any call can throw), and
    // evalExpression returns JSValue, not Completion -- a Completion-only
    // channel can't cross expression frames or the Callable.call vtable
    // boundary (a published z-value interface). Throws travel as the
    // module-private `error.JsThrow` Zig error plus the Interpreter's
    // `pending_exception` side channel instead; see interpreter.zig's
    // Outcome/runCapturing for where the two channels merge (try/finally).
};

/// ECMA-262's real Completion Record shape ({ type, value, target }), not a
/// bare control-flow tag: carrying `value` on `.normal` lets a StatementList
/// evaluator's "last statement's value" propagate for free, which is what
/// `Interpreter.run()` returns.
pub const Completion = struct {
    type: CompletionType = .normal,
    /// Meaningful for `.normal` (the value of the last expression
    /// evaluated) and `.return_completion` (the returned value). UNDEFINED
    /// for break/continue.
    value: JSValue = JSValue.UNDEFINED,
    /// Label name for break/continue; null = unlabelled. Labelled
    /// break/continue are not evaluated this phase (see Interpreter) --
    /// this field exists so a future phase can add label-stack support
    /// without reshaping this type again.
    target: ?[]const u8 = null,
};
