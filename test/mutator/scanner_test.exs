defmodule Mutator.ScannerTest do
  @moduledoc """
  M3 gate: every enabled operator finds its site; every negative syntax case
  is left alone. Each case names the operator vocabulary from MVP_PLAN.md §1.
  """

  use ExUnit.Case, async: true

  alias Mutator.Scanner


  defp zscan(src), do: Scanner.scan(:zig, "src/a.zig", src)
  defp escan(src), do: Scanner.scan(:elixir, "lib/a.ex", src)
  defp sscan(src), do: Scanner.scan(:swift, "Src/a.swift", src)
  defp kscan(src), do: Scanner.scan(:kotlin, "src/A.kt", src)

  describe "zig operators" do
    test "arithmetic binary + and -" do
      src = """
      pub fn add(a: u32, b: u32) u32 {
          return a + b;
      }

      pub fn sub(a: u32, b: u32) u32 {
          return a - b;
      }
      """

      assert {{"arith", "+", "-"}, 1} = count(zscan(src), {"arith", "+", "-"})
      assert {{"arith", "-", "+"}, 1} = count(zscan(src), {"arith", "-", "+"})
    end

    test "equality and comparison" do
      src = """
      fn f(a: u32, b: u32) bool {
          if (a == b) return true;
          if (a != b) return false;
          if (a < b) return true;
          if (a <= b) return true;
          if (a > b) return true;
          if (a >= b) return true;
          return false;
      }
      """

      sites = zscan(src)
      assert {{"equality", "==", "!="}, 1} = count(sites, {"equality", "==", "!="})
      assert {{"equality", "!=", "=="}, 1} = count(sites, {"equality", "!=", "=="})
      assert {{"comparison", "<", "<="}, 1} = count(sites, {"comparison", "<", "<="})
      assert {{"comparison", "<=", "<"}, 1} = count(sites, {"comparison", "<=", "<"})
      assert {{"comparison", ">", ">="}, 1} = count(sites, {"comparison", ">", ">="})
      assert {{"comparison", ">=", ">"}, 1} = count(sites, {"comparison", ">=", ">"})
      # true/false flips: `return true` on the ==, <, <=, >, >= lines (5) and
      # `return false` on the != line plus the final return (2)
      assert {{"bool", "true", "false"}, 5} = count(sites, {"bool", "true", "false"})
      assert {{"bool", "false", "true"}, 2} = count(sites, {"bool", "false", "true"})
    end

    test "logical and/or keywords" do
      src = """
      fn f(a: bool, b: bool) bool {
          return a and b or (a or b);
      }
      """

      assert {{"logical", "and", "or"}, 1} = count(zscan(src), {"logical", "and", "or"})
      assert {{"logical", "or", "and"}, 2} = count(zscan(src), {"logical", "or", "and"})
    end

    test "delete boolean not in prefix position" do
      src = """
      fn f(ok: bool) bool {
          if (!ok) return false;
          return !(ok) ;
      }
      """

      assert {{"unary_del", "!", ""}, 2} = count(zscan(src), {"unary_del", "!", ""})
    end

    test "delete unary minus only in prefix position" do
      src = """
      fn f(a: i32) i32 {
          const x = -a;
          return x - a;
      }
      """

      sites = zscan(src)
      assert {{"unary_del", "-", ""}, 1} = count(sites, {"unary_del", "-", ""})
      assert {{"arith", "-", "+"}, 1} = count(sites, {"arith", "-", "+"})
    end

    test "constants 0 and 1" do
      src = """
      fn f(a: u32) u32 {
          if (a == 0) return 1;
          return 0;
      }
      """

      assert {{"const01", "0", "1"}, 2} = count(zscan(src), {"const01", "0", "1"})
      assert {{"const01", "1", "0"}, 1} = count(zscan(src), {"const01", "1", "0"})
    end
  end

  describe "zig negative syntax" do
    test "pointer types are never mutated" do
      src = """
      fn f(p: *const u8, q: *u8, n: usize) void {
          const a = p.* == q;
          _ = n;
      }
      """

      # `*const`, `*u8` untouched; `p.*` deref untouched; `==` inside body found
      sites = zscan(src)
      assert {{"equality", "==", "!="}, 1} = count(sites, {"equality", "==", "!="})
      refute Enum.any?(sites, &(&1.original == "*" and &1.file == "src/a.zig" and &1.operator == "arith"))
    end

    test "error-union suffix ! is never deleted" do
      src = """
      const E = error{X};

      fn g() E!void {
          return;
      }

      fn h(x: bool) !void {
          if (x) return error.X;
      }
      """

      sites = zscan(src)
      refute Enum.any?(sites, &(&1.operator == "unary_del" and &1.original == "!"))
    end

    test "operators in strings, comments, and test bodies are skipped" do
      src = """
      // a + b == c
      fn f() u32 {
          // 1 + 2 == 3
          const s = "a + b == true";
          _ = s;
          return 1;
      }

      test "maths" {
          try std.testing.expectEqual(1 + 1, 2);
      }
      """

      sites = zscan(src)
      # only the `return 1` constant survives
      assert [%{operator: "const01", original: "1"}] = sites
    end

    test "shifts and mul/div are not in the Zig vocabulary" do
      src = """
      fn f(a: u32) u32 {
          const b = a * 2;
          const c = a / 2;
          const d = a << 1;
          return d - b - c;
      }
      """

      sites = zscan(src)
      refute Enum.any?(sites, &(&1.original in ["*", "/", "<<"]))
      assert {{"arith", "-", "+"}, 2} = count(sites, {"arith", "-", "+"})
    end

    test "top-level initializers are skipped" do
      src = """
      const LIMIT: u32 = 1 + 2;

      fn f() u32 {
          return LIMIT;
      }
      """

      assert zscan(src) == []
    end
  end

  describe "elixir operators" do
    test "core set" do
      src = """
      defmodule Demo do
        def f(a, b) do
          x = a + b
          y = x - 1
          z = x * 2
          w = z / 2
          eq = a == b
          lt = a < b
          le = a <= b
          gt = a > b
          ge = a >= b
          l1 = a > 0 and b < 1
          l2 = a > 0 || b < 0
          not_e = !eq
          n = -y
          truthy = true
          falsy = false
          {x, y, z, w, eq, lt, le, gt, ge, l1, l2, not_e, n, truthy, falsy}
        end
      end
      """

      sites = escan(src)

      assert {{"arith", "+", "-"}, 1} = count(sites, {"arith", "+", "-"})
      assert {{"arith", "-", "+"}, 1} = count(sites, {"arith", "-", "+"})
      assert {{"arith", "*", "/"}, 1} = count(sites, {"arith", "*", "/"})
      assert {{"arith", "/", "*"}, 1} = count(sites, {"arith", "/", "*"})
      assert {{"equality", "==", "!="}, 1} = count(sites, {"equality", "==", "!="})
      assert {{"comparison", "<", "<="}, 3} = count(sites, {"comparison", "<", "<="})
      assert {{"comparison", "<=", "<"}, 1} = count(sites, {"comparison", "<=", "<"})
      assert {{"comparison", ">", ">="}, 3} = count(sites, {"comparison", ">", ">="})
      assert {{"comparison", ">=", ">"}, 1} = count(sites, {"comparison", ">=", ">"})
      assert {{"logical", "and", "or"}, 1} = count(sites, {"logical", "and", "or"})
      assert {{"logical", "||", "&&"}, 1} = count(sites, {"logical", "||", "&&"})
      assert {{"unary_del", "!", ""}, 1} = count(sites, {"unary_del", "!", ""})
      assert {{"unary_del", "-", ""}, 1} = count(sites, {"unary_del", "-", ""})
      assert {{"bool", "true", "false"}, 1} = count(sites, {"bool", "true", "false"})
      assert {{"bool", "false", "true"}, 1} = count(sites, {"bool", "false", "true"})
      assert {{"const01", "0", "1"}, 3} = count(sites, {"const01", "0", "1"})
      assert {{"const01", "1", "0"}, 2} = count(sites, {"const01", "1", "0"})
    end

    test "test bodies excluded; do: one-liners skipped (documented subset)" do
      src = """
      defmodule DemoTest do
        use ExUnit.Case

        test "adds" do
          assert 1 + 1 == 2
        end

        def helper(a), do: a + 1
      end
      """

      assert escan(src) == []
    end

    test "strings, sigils, comments, atoms untouched" do
      src = """
      defmodule Demo do
        # a + b == c
        def f(a) do
          s = "a + b == c"
          r = ~s(x * y)
          op = :==
          char = ?+
          op2 = :"||"
          a
        end
      end
      """

      assert escan(src) == []
    end
  end

  describe "swift operators" do
    test "core set with generic-safe comparisons" do
      src = """
      struct Box<T> { var v: T }

      func f(a: Int, b: Int) -> Int {
          let s = a + b
          let d = a - b
          if a == b { return 1 }
          if arr[0] < b { return 2 }
          let both = a > 0 && b > 0
          let either = a > 0 || b > 0
          let notA = !both
          let neg = -a
          return s - d
      }
      """

      sites = sscan(src)
      assert {{"arith", "+", "-"}, 1} = count(sites, {"arith", "+", "-"})
      assert {{"equality", "==", "!="}, 1} = count(sites, {"equality", "==", "!="})
      assert {{"comparison", "<", "<="}, 1} = count(sites, {"comparison", "<", "<="})
      assert {{"logical", "&&", "||"}, 1} = count(sites, {"logical", "&&", "||"})
      assert {{"logical", "||", "&&"}, 1} = count(sites, {"logical", "||", "&&"})
      assert {{"unary_del", "!", ""}, 1} = count(sites, {"unary_del", "!", ""})
      assert {{"unary_del", "-", ""}, 1} = count(sites, {"unary_del", "-", ""})
    end

    test "generics and force-unwrap are not mutated" do
      src = """
      func f(box: Box<Int>) -> Int {
          let g = makePair(a, b).first
          return g
      }
      """

      sites = sscan(src)
      refute Enum.any?(sites, &(&1.original in ["<", ">", "!"]))
    end

    test "XCTest-style test functions are excluded" do
      src = """
      func testAddition() {
          let x = 1 + 1
          XCTAssert(x == 2)
      }

      func realWork(a: Int) -> Int {
          return a + 1
      }
      """

      sites = sscan(src)
      assert length(sites) == 2
      assert Enum.all?(sites, &(&1.function == "realWork"))
    end
  end

  describe "kotlin operators" do
    test "core set including referential equality" do
      src = """
      fun f(a: Int, b: Int): Int {
          val s = a + b
          val same = a === b
          val diff = a !== b
          val both = a > 0 && b > 0
          val notA = !both
          val neg = -a
          return s
      }
      """

      sites = kscan(src)
      assert {{"equality", "===", "!=="}, 1} = count(sites, {"equality", "===", "!=="})
      assert {{"equality", "!==", "==="}, 1} = count(sites, {"equality", "!==", "==="})
      assert {{"logical", "&&", "||"}, 1} = count(sites, {"logical", "&&", "||"})
      assert {{"unary_del", "!", ""}, 1} = count(sites, {"unary_del", "!", ""})
      assert {{"unary_del", "-", ""}, 1} = count(sites, {"unary_del", "-", ""})
    end

    test "!in, !is, and !! are never mutated" do
      src = """
      fun f(x: Any, list: List<Int>): Boolean {
          val a = 3 !in list
          val b = x !is String
          val s = (x as String)!!
          return a
      }
      """

      sites = kscan(src)
      refute Enum.any?(sites, &(&1.operator == "unary_del"))
    end
  end

  describe "site keys and patching" do
    test "site keys are deterministic and byte spans patch exactly" do
      src = """
      fn f(a: u32, b: u32) u32 {
          return a + b;
      }
      """

      [site] = zscan(src)
      assert site.function == "f"
      assert site.original == "+"
      assert binary_part(src, site.byte_start, site.byte_end - site.byte_start) == "+"

      patched =
        binary_part(src, 0, site.byte_start) <>
          site.replacement <> binary_part(src, site.byte_end, byte_size(src) - site.byte_end)

      assert patched =~ "return a - b;"

      [again] = zscan(src)
      assert again.site_key == site.site_key
    end
  end

  defp count(sites, key) do
    n = Enum.count(sites, fn s -> {s.operator, s.original, s.replacement} == key end)
    {key, n}
  end
end
