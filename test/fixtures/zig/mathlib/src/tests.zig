const std = @import("std");
const math = @import("math.zig");

test "add sums" {
    try std.testing.expectEqual(@as(u32, 5), math.add(2, 3));
    try std.testing.expectEqual(@as(u32, 0), math.add(0, 0));
}

test "clamp below" {
    try std.testing.expectEqual(@as(u32, 3), math.clamp(1, 3, 9));
}

test "sign of x" {
    try std.testing.expectEqual(@as(i32, 1), math.sign(7));
    try std.testing.expectEqual(@as(i32, 0), math.sign(0));
    try std.testing.expectEqual(@as(i32, -1), math.sign(-7));
}
