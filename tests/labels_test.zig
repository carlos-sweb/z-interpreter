const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");

test "labelled break out of nested loops (the classic)" {
    try helpers.expectNumber(
        \\var count = 0;
        \\outer: for (var i = 0; i < 5; i = i + 1) {
        \\  for (var j = 0; j < 5; j = j + 1) {
        \\    if (i == 1 && j == 1) { break outer; }
        \\    count += 1;
        \\  }
        \\}
        \\count;
    ,
        6, // i=0: j=0..4 (5), i=1: j=0 (1), then out entirely
    );
}

test "labelled continue advances the OUTER loop" {
    try helpers.expectNumber(
        \\var count = 0;
        \\outer: for (var i = 0; i < 3; i = i + 1) {
        \\  for (var j = 0; j < 3; j = j + 1) {
        \\    if (j == 1) { continue outer; }
        \\    count += 1;
        \\  }
        \\}
        \\count;
    ,
        3, // each outer iteration counts only j=0
    );
}

test "labelled break of a plain block (non-loop)" {
    try helpers.expectNumber(
        "var r = 0; a: { r += 1; break a; r += 100; } r;",
        1,
    );
}

test "chained labels: break/continue by either name" {
    try helpers.expectNumber(
        "var n = 0; a: b: for (;;) { n += 1; if (n == 2) { break a; } } n;",
        2,
    );
    try helpers.expectNumber(
        "var n = 0; a: b: for (;;) { n += 1; if (n == 2) { break b; } } n;",
        2,
    );
    try helpers.expectNumber(
        \\var count = 0;
        \\a: b: for (var i = 0; i < 3; i = i + 1) {
        \\  count += 1;
        \\  continue a;
        \\  count += 100;
        \\}
        \\count;
    ,
        3,
    );
}

test "labelled break travels through a switch to the labelled loop" {
    try helpers.expectNumber(
        \\var r = 0;
        \\a: for (var i = 0; i < 5; i = i + 1) {
        \\  switch (i) {
        \\    case 2: break a;
        \\    default: r += 1;
        \\  }
        \\}
        \\r;
    ,
        2, // i=0,1 count; i=2 breaks the LOOP, not just the switch
    );
}

test "label on an if statement" {
    try helpers.expectNumber("var r = 0; a: if (true) { r += 1; break a; r += 100; } r;", 1);
}

test "labelled break through a finally: the finally runs, the break still exits" {
    try helpers.expectNumber(
        \\var fin = 0;
        \\var iterations = 0;
        \\outer: for (var i = 0; i < 5; i = i + 1) {
        \\  iterations += 1;
        \\  try {
        \\    if (i == 1) { break outer; }
        \\  } finally {
        \\    fin += 1;
        \\  }
        \\}
        \\fin * 10 + iterations;
    ,
        22, // finally ran twice (i=0, i=1), loop iterated twice
    );
}

test "labelled continue skips to the outer loop's update through inner nesting" {
    try helpers.expectNumber(
        \\var log = 0;
        \\outer: for (var i = 0; i < 3; i = i + 1) {
        \\  while (true) {
        \\    log += 1;
        \\    continue outer;
        \\  }
        \\}
        \\log;
    ,
        3, // the inner while(true) never spins: continue outer exits it each time
    );
}
