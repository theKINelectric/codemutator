// Subject with deliberate mutation sites, mirroring the zig mathlib fixture:
// - add(): `+` flip is KILLED by tests
// - clamp(): `normalized(v) < lo` boundary flip SURVIVES (tests never probe
//   equality at the boundary), while the `&&` flip is KILLED
// - sign(): unary `-` deletion and literal flips are KILLED
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

fn normalized(v: i32) -> i32 {
    v
}

pub fn clamp(v: i32, lo: i32, hi: i32) -> i32 {
    if normalized(v) < lo && hi > lo {
        return lo;
    }
    if v > hi {
        return hi;
    }
    v
}

pub fn sign(x: i32) -> i32 {
    if x == 0 {
        return 0;
    }
    if x > 0 {
        return 1;
    }
    -1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
        assert_eq!(add(0, 1), 1);
    }

    #[test]
    fn test_clamp() {
        assert_eq!(clamp(5, 0, 10), 5);
        assert_eq!(clamp(20, 0, 10), 10);
        // never exercises the low boundary with equality: `<` flip survives
    }

    #[test]
    fn test_sign() {
        assert_eq!(sign(0), 0);
        assert_eq!(sign(3), 1);
        assert_eq!(sign(-3), -1);
    }
}
