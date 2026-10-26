// Subject with deliberate mutation sites:
// - add(): `+` flip is KILLED by tests
// - clamp(): `and` flip SURVIVES (boundary never tested with both edges)
// - sign(): unary `-` deletion is KILLED
pub fn add(a: u32, b: u32) u32 {
    return a + b;
}

pub fn clamp(v: u32, lo: u32, hi: u32) u32 {
    if (v < lo and hi > lo) {
        return lo;
    }
    if (v > hi) {
        return hi;
    }
    return v;
}

pub fn sign(x: i32) i32 {
    if (x == 0) {
        return 0;
    }
    if (x > 0) {
        return 1;
    }
    return -1;
}
