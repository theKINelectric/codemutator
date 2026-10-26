defmodule Mutator.Scanner do
  @moduledoc """
  Finds mutation sites in one source file.

  Two passes over the token stream:

    1. **Blocks** — match `{...}` (C-like) or `do...end` (Elixir) spans and
       classify each as `:function`, `:test`, or `:other`. Sites are emitted
       only inside `:function` spans, and never inside a `:test` span
       (embedded tests are excluded by content, not filename — MVP_PLAN.md §1).
    2. **Operators** — apply the language's mutation table to tokens inside
       function spans, guarded by the previous/next significant token so that
       prefix position (`!x`, `-x`) is distinguished from infix position
       (`a == b`), and type syntax (`*T` pointers, `E!T` error unions,
       `x!` unwraps, generics) is never mutated.

  Supported subset (deliberate, recorded in README): single-clause `do:`
  bodies in Elixir are skipped; top-level initializers, comptime bodies, and
  test bodies are skipped in Zig; Swift/Kotlin comparisons require a definite
  expression LHS to avoid generics.

  Sites carry deterministic `site_key`s (file hash + byte span + operator +
  replacement): the same file always yields the same keys.
  """

  alias Mutator.Scanner.Lexer
  alias Mutator.Scanner.Lexer.Token

  # Tokens after which the next token is in prefix (expression-start)
  # position. Idents like `return`, `and`, `or`, `if` start expressions; other
  # idents end them (operand position).
  @prefix_idents [
    "return",
    "and",
    "or",
    "orelse",
    "catch",
    "else",
    "try",
    "comptime",
    "if",
    "while",
    "for",
    "switch",
    "defer",
    "not",
    "do",
    "then",
    "case",
    "in",
    "as",
    "is",
    "where",
    "select",
    "suspend",
    "resume",
    "align",
    "test",
    "fn",
    "const",
    "var",
    "pub",
    "export",
    "inline",
    "noalias",
    "volatile",
    "allowzero",
    "linksection",
    "callconv",
    "unreachable",
    "break",
    "continue",
    "errdefer",
    "usingnamespace",
    "false",
    "true",
    "struct",
    "union",
    "enum",
    "opaque",
    "error",
    "packed",
    "extern",
    "when",
    "guard",
    "let",
    "val",
    "init",
    "deinit",
    # rust declaration/expression keywords; operand-like idents (`self`,
    # `Self`, `super`, `crate`, `await`, `Some`/`None`/`Ok`/`Err`) stay out
    "mut",
    "ref",
    "match",
    "loop",
    "unsafe",
    "async",
    "dyn",
    "box",
    "impl",
    "mod",
    "use",
    "type",
    "trait",
    "move",
    "macro_rules",
    "macro",
    "static",
    "yield",
    "raw",
    "default"
  ]

  @prefix_ops [
    "(",
    "[",
    "{",
    ",",
    "=",
    ";",
    "!",
    "&&",
    "||",
    "==",
    "!=",
    "<",
    "<=",
    ">",
    ">=",
    "+",
    "-",
    "*",
    "/",
    "->",
    "=>",
    "::",
    "..",
    "..<",
    "?:",
    "!!",
    "|>",
    "|",
    "&",
    ":",
    "else",
    "when",
    "catch",
    "return",
    "not",
    "and",
    "or"
  ]

  defmodule Site do
    @enforce_keys [
      :file,
      :function,
      :function_line,
      :function_end_line,
      :line,
      :byte_start,
      :byte_end,
      :operator,
      :original,
      :replacement,
      :site_key
    ]

    defstruct [
      :file,
      :function,
      :function_line,
      :function_end_line,
      :line,
      :byte_start,
      :byte_end,
      :operator,
      :original,
      :replacement,
      :site_key,
      file_hash: nil
    ]
  end

  defmodule Profile do
    @moduledoc """
    Mutation profile for one language. `operators` maps token text ->
    replacement (infix position only); `delete_unary` lists tokens deleted in
    prefix position; `unary_next_skip` blocks prefix deletion when the next
    token is one of these idents (Kotlin `!in`, `!is`). Comparisons listed in
    `comparison_lhs_ops_only` (Swift/Kotlin) require a definite expression
    LHS (`)`, `]`, literal, string) so generic brackets are never mutated.
    """
    defstruct [
      :language,
      :block_style,
      :fn_keywords,
      :test_keywords,
      :test_name_prefixes,
      :operators,
      :delete_unary,
      :unary_next_skip,
      :bools,
      :infix_idents,
      :comparison_lhs_ops_only
    ]
  end

  defmodule Block do
    @enforce_keys [:kind, :name, :start_byte, :stop_byte, :depth]
    defstruct [:kind, :name, :start_byte, :stop_byte, :depth]
  end

  # -- profiles --------------------------------------------------------------

  def zig_profile do
    %Profile{
      language: :zig,
      block_style: :brace,
      fn_keywords: ["fn"],
      test_keywords: ["test"],
      test_name_prefixes: [],
      operators: %{
        "==" => "!=",
        "!=" => "==",
        "<" => "<=",
        "<=" => "<",
        ">" => ">=",
        ">=" => ">",
        "+" => "-",
        "-" => "+"
      },
      delete_unary: ["!", "-"],
      unary_next_skip: [],
      bools: %{"true" => "false", "false" => "true"},
      infix_idents: %{"and" => "or", "or" => "and"},
      comparison_lhs_ops_only: nil
    }
  end

  def elixir_profile do
    %Profile{
      language: :elixir,
      block_style: :do_end,
      fn_keywords: ["def", "defp"],
      test_keywords: ["test", "describe"],
      test_name_prefixes: [],
      operators: %{
        "==" => "!=",
        "!=" => "==",
        "<" => "<=",
        "<=" => "<",
        ">" => ">=",
        ">=" => ">",
        "+" => "-",
        "-" => "+",
        "*" => "/",
        "/" => "*",
        "&&" => "||",
        "||" => "&&"
      },
      delete_unary: ["!", "-", "not"],
      unary_next_skip: [],
      bools: %{"true" => "false", "false" => "true"},
      infix_idents: %{"and" => "or", "or" => "and"},
      comparison_lhs_ops_only: nil
    }
  end

  def swift_profile do
    %Profile{
      language: :swift,
      block_style: :brace,
      fn_keywords: ["func"],
      test_keywords: [],
      test_name_prefixes: ["test"],
      operators: %{
        "==" => "!=",
        "!=" => "==",
        "+" => "-",
        "-" => "+",
        "&&" => "||",
        "||" => "&&"
      },
      delete_unary: ["!", "-"],
      unary_next_skip: [],
      bools: %{"true" => "false", "false" => "true"},
      infix_idents: %{},
      comparison_lhs_ops_only: %{"<" => "<=", "<=" => "<", ">" => ">=", ">=" => ">"}
    }
  end

  def kotlin_profile do
    %Profile{
      language: :kotlin,
      block_style: :brace,
      fn_keywords: ["fun"],
      test_keywords: [],
      test_name_prefixes: ["test"],
      operators: %{
        "==" => "!=",
        "!=" => "==",
        "===" => "!==",
        "!==" => "===",
        "+" => "-",
        "-" => "+",
        "&&" => "||",
        "||" => "&&"
      },
      delete_unary: ["!", "-"],
      unary_next_skip: ["in", "is"],
      bools: %{"true" => "false", "false" => "true"},
      infix_idents: %{},
      comparison_lhs_ops_only: %{"<" => "<=", "<=" => "<", ">" => ">=", ">=" => ">"}
    }
  end

  def rust_profile do
    %Profile{
      language: :rust,
      block_style: :brace,
      fn_keywords: ["fn"],
      # `#[test]` lexes as ident `test` at paren depth 0 (the `(` under it is
      # only `cfg(..)` args); `mod tests`/`mod test` name the conventional
      # test module. A test pending then survives the `fn` decl it annotates.
      test_keywords: ["test", "tests"],
      test_name_prefixes: ["test"],
      operators: %{
        "==" => "!=",
        "!=" => "==",
        "+" => "-",
        "-" => "+",
        "*" => "/",
        "/" => "*",
        "&&" => "||",
        "||" => "&&"
      },
      delete_unary: ["!", "-"],
      unary_next_skip: [],
      bools: %{"true" => "false", "false" => "true"},
      infix_idents: %{},
      # `x < y` with an ident LHS stays unmutated — `<` opens generic argument
      # lists (`Vec<T>`), and only `)`/`]`/literal/`?` left-hand sides are a
      # definite expression. Same policy as Swift/Kotlin.
      comparison_lhs_ops_only: %{"<" => "<=", "<=" => "<", ">" => ">=", ">=" => ">"}
    }
  end

  def profile(:zig), do: zig_profile()
  def profile(:elixir), do: elixir_profile()
  def profile(:swift), do: swift_profile()
  def profile(:kotlin), do: kotlin_profile()
  def profile(:rust), do: rust_profile()

  # -- scanning --------------------------------------------------------------

  @doc "Scan one file's bytes; returns sites in byte order."
  def scan(language, rel_path, source) when is_binary(source) do
    profile = profile(language)
    config = lexer_config(language)
    {tokens, line_starts} = Lexer.lex(source, config)
    code = Enum.filter(tokens, &(&1.kind != :skipped))
    indexed = Enum.with_index(code)
    blocks = find_blocks(code, profile)

    attribution = attribute_blocks(blocks, code)

    indexed
    |> Enum.flat_map(fn {token, i} ->
      case attribution[i] || :none do
        :excluded -> []
        :none -> []
        {:ok, block} -> sites_for(token, i, code, block, profile, line_starts, rel_path)
      end
    end)
    |> Enum.sort_by(& &1.byte_start)
    |> attach_keys(rel_path, source)
  end

  def scan(_, _, _), do: []

  defp lexer_config(:zig), do: Lexer.zig_config()
  defp lexer_config(:elixir), do: Lexer.elixir_config()
  defp lexer_config(:swift), do: Lexer.swift_config()
  defp lexer_config(:kotlin), do: Lexer.kotlin_config()
  defp lexer_config(:rust), do: Lexer.rust_config()

  @doc "SHA-256 of file content, used to key sites."
  def file_hash(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp attach_keys(sites, rel_path, source) do
    hash = file_hash(source)

    Enum.map(sites, fn site ->
      key =
        :crypto.hash(:sha256, "#{hash}:#{site.byte_start}:#{site.operator}:#{site.replacement}")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 32)

      %{site | site_key: key, file: rel_path}
    end)
  end

  # -- block discovery -------------------------------------------------------

  defp find_blocks(code, %Profile{block_style: :brace} = profile) do
    indexed = Enum.with_index(code)

    # state: %{stack: [Block], pending: {kind, name} | nil, paren: depth}.
    # Paren depth guards default-arg braces; the pending decl survives the
    # parameter list of the function it belongs to.
    {_state, closed} =
      Enum.reduce(indexed, {%{stack: [], pending: nil, paren: 0}, []}, fn {token, i},
                                                                          {state, closed} ->
        case token do
          %Token{kind: :op, text: "("} ->
            {update_in(state, [:paren], &(&1 + 1)), closed}

          %Token{kind: :op, text: ")"} ->
            {update_in(state, [:paren], &max(&1 - 1, 0)), closed}

          %Token{kind: :op, text: "{"} ->
            depth = length(state.stack)

            {kind, name} =
              if state.paren == 0 do
                state.pending || {nil, nil}
              else
                {:other, nil}
              end

            entry = %Block{
              kind: kind || :other,
              name: name,
              start_byte: token.start,
              stop_byte: :open,
              depth: depth
            }

            {%{state | stack: [entry | state.stack], pending: nil}, closed}

          %Token{kind: :op, text: "}"} ->
            case state.stack do
              [%Block{stop_byte: :open} = top | rest] ->
                {%{state | stack: rest}, [%{top | stop_byte: token.stop} | closed]}

              _ ->
                {state, closed}
            end

          %Token{kind: :op, text: ";"} when state.paren == 0 ->
            {%{state | pending: nil}, closed}

          %Token{kind: :ident, text: text} ->
            cond do
              text in profile.fn_keywords and state.paren == 0 ->
                case fn_name_at(code, i) do
                  nil ->
                    {state, closed}

                  name ->
                    # A pending `:test` (Rust `#[test]`, or a `test`-keyword
                    # attribute) annotates this fn decl — it wins over the
                    # function kind, same as a `test`-prefixed name.
                    decl =
                      if match?({:test, _}, state.pending) or test_named?(name, profile) do
                        {:test, name}
                      else
                        {:function, name}
                      end

                    {%{state | pending: decl}, closed}
                end

              text in profile.test_keywords and state.paren == 0 ->
                {%{state | pending: {:test, nil}}, closed}

              true ->
                {state, closed}
            end

          _ ->
            {state, closed}
        end
      end)

    closed
  end

  defp find_blocks(code, %Profile{block_style: :do_end} = profile) do
    code = mark_do_colon(code)
    indexed = Enum.with_index(code)

    {_state, closed} =
      Enum.reduce(indexed, {%{stack: [], pending: nil}, []}, fn {token, i}, {state, closed} ->
        case token do
          %Token{kind: :do_open} ->
            depth = length(state.stack)
            {kind, name} = state.pending || {nil, nil}

            entry = %Block{
              kind: kind || :other,
              name: name,
              start_byte: token.start,
              stop_byte: :open,
              depth: depth
            }

            {%{state | stack: [entry | state.stack], pending: nil}, closed}

          %Token{kind: :ident, text: "end"} ->
            case state.stack do
              [%Block{stop_byte: :open} = top | rest] ->
                {%{state | stack: rest}, [%{top | stop_byte: token.stop} | closed]}

              _ ->
                {state, closed}
            end

          %Token{kind: :ident, text: text} ->
            cond do
              text in profile.fn_keywords ->
                case fn_name_at(code, i) do
                  nil -> {state, closed}
                  name -> {%{state | pending: {:function, name}}, closed}
                end

              text in profile.test_keywords ->
                {%{state | pending: {:test, nil}}, closed}

              true ->
                {state, closed}
            end

          _ ->
            {state, closed}
        end
      end)

    closed
  end

  # `testFoo` naming marks XCTest/JUnit bodies as tests even without a
  # `test` keyword form.
  defp test_named?(name, %Profile{test_name_prefixes: prefixes}) do
    prefixes != [] and Enum.any?(prefixes, &String.starts_with?(name, &1))
  end

  # `do:` keyword-list form: ident `do` immediately followed by op `:` opens
  # nothing. Everything else named `do` opens a block.
  defp mark_do_colon(code) do
    count = length(code)

    Enum.map(Enum.with_index(code), fn {token, i} ->
      next = if i + 1 < count, do: Enum.at(code, i + 1), else: nil

      case {token, next} do
        {%Token{kind: :ident, text: "do"}, %Token{text: ":"}} -> token
        {%Token{kind: :ident, text: "do"}, _} -> %{token | kind: :do_open}
        _ -> token
      end
    end)
  end

  defp fn_name_at(code, i) do
    case Enum.at(code, i + 1) do
      %Token{kind: :ident, text: name} -> name
      _ -> nil
    end
  end

  # A function name (declared on the fn block) is stored on the block when it
  # opens; test-name prefixes override function kind for XCTest/JUnit naming.
  # Single pass: tokens and blocks are both in byte order, so attribution is
  # linear — a per-token filter over all blocks was quadratic on real files
  # (854k-token subjects took minutes; now seconds).
  defp attribute_blocks(blocks, code) do
    pending = Enum.sort_by(blocks, &{&1.start_byte, -&1.depth})
    do_attribute(pending, Enum.with_index(code), [], %{})
  end

  defp do_attribute(_pending, [], _active, acc), do: acc

  defp do_attribute(pending, [{token, i} | rest], active, acc) do
    {entering, pending} = Enum.split_while(pending, &(&1.start_byte <= token.start))
    active = Enum.reject(active ++ entering, &(&1.stop_byte <= token.start))

    value =
      cond do
        active == [] ->
          :none

        Enum.any?(active, &(&1.kind == :test)) ->
          :excluded

        true ->
          case Enum.filter(active, &(&1.kind == :function)) do
            [] -> :none
            fns -> {:ok, Enum.max_by(fns, & &1.depth)}
          end
      end

    do_attribute(pending, rest, active, Map.put(acc, i, value))
  end

  # -- operator application --------------------------------------------------

  defp sites_for(%Token{} = token, i, code, block, profile, line_starts, rel_path) do
    prev = if i > 0, do: Enum.at(code, i - 1), else: nil
    next_t = Enum.at(code, i + 1)

    candidates(token, prev, next_t, profile)
    |> Enum.map(fn {operator, original, replacement} ->
      %Site{
        file: rel_path,
        function: block.name || "(anonymous)",
        function_line: line_of(block.start_byte, line_starts),
        function_end_line: line_of(block.stop_byte, line_starts),
        line: line_of(token.start, line_starts),
        byte_start: token.start,
        byte_end: token.stop,
        operator: operator,
        original: original,
        replacement: replacement,
        site_key: nil
      }
    end)
  end

  defp line_of(byte, line_starts), do: Lexer.line_of(line_starts, byte)

  defp candidates(%Token{kind: :number, text: "0"}, _prev, _next, _profile),
    do: [{"const01", "0", "1"}]

  defp candidates(%Token{kind: :number, text: "1"}, _prev, _next, _profile),
    do: [{"const01", "1", "0"}]

  defp candidates(%Token{kind: :ident, text: text}, prev, _next, profile) do
    cond do
      Map.has_key?(profile.bools, text) ->
        [{"bool", text, profile.bools[text]}]

      Map.has_key?(profile.infix_idents, text) and prev_operand?(prev) ->
        [{"logical", text, profile.infix_idents[text]}]

      text in profile.delete_unary and prefix_position?(prev) ->
        [{"unary_del", text, ""}]

      true ->
        []
    end
  end

  defp candidates(%Token{kind: :op, text: text}, prev, next_t, profile) do
    cond do
      comparison = (profile.comparison_lhs_ops_only || %{})[text] ->
        if lhs_definite_operand?(prev),
          do: [{op_category(text), text, comparison}],
          else: []

      Map.has_key?(profile.operators, text) and prev_operand?(prev) ->
        [{op_category(text), text, profile.operators[text]}]

      text in profile.delete_unary and prefix_position?(prev) and
          not unary_next_blocked?(next_t, profile) ->
        [{"unary_del", text, ""}]

      true ->
        []
    end
  end

  defp candidates(_token, _prev, _next, _profile), do: []

  defp op_category(t) when t in ["+", "-", "*", "/"], do: "arith"
  defp op_category(t) when t in ["<", "<=", ">", ">="], do: "comparison"
  defp op_category(t) when t in ["==", "!=", "===", "!=="], do: "equality"
  defp op_category(_), do: "logical"

  defp prev_operand?(nil), do: false

  defp prev_operand?(%Token{} = prev) do
    case prev do
      %Token{kind: :number} -> true
      %Token{kind: :atom_op} -> true
      %Token{kind: :skipped} -> true
      %Token{kind: :op, text: t} -> t in [")", "]", "}", ".*", "!?", "!!", "!", "?"]
      %Token{kind: :ident, text: t} -> t not in @prefix_idents
      _ -> false
    end
  end

  # A definite expression LHS: closing bracket, literal, or string — never a
  # bare identifier that could open a generic argument list.
  defp lhs_definite_operand?(%Token{kind: :op, text: t}) when t in [")", "]"], do: true
  defp lhs_definite_operand?(%Token{kind: :number}), do: true
  defp lhs_definite_operand?(%Token{kind: :skipped}), do: true
  defp lhs_definite_operand?(_), do: false

  defp prefix_position?(nil), do: true

  defp prefix_position?(%Token{} = prev) do
    case prev do
      %Token{kind: :ident, text: t} -> t in @prefix_idents
      %Token{kind: :op, text: t} -> t in @prefix_ops
      _ -> false
    end
  end

  defp unary_next_blocked?(%Token{kind: :ident, text: t}, %Profile{unary_next_skip: skip}),
    do: t in skip

  defp unary_next_blocked?(_, _), do: false
end
