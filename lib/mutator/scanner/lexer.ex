defmodule Mutator.Scanner.Lexer do
  @moduledoc """
  A conservative hand-rolled lexer for the four service languages.

  It exists to place every mutation candidate at a byte offset while skipping
  strings, character literals, comments, and other non-code spans — the places
  the reference tool also refuses to mutate. When a construct is ambiguous the
  lexer keeps it whole rather than emitting tokens that could mislead the
  scanner: an unrecognized construct is never mutated (MVP_PLAN.md §1).

  Tokens carry 0-based UTF-8 byte offsets into the original binary:

    * `{:ident, text}`  — identifiers and keywords (`true`, `fn`, `def`...)
    * `{:number, text}` — numeric literals, kept whole (`10`, `0x1F`, `1.5`)
    * `{:atom_op, text}` — Elixir operator/quoted atoms (`:==`, `:"+"`), whole
    * `{:op, text}`     — operators and punctuation, maximal munch
    * `{:skipped, kind}` — `:comment` | `:string` | `:raw_string` |
                           `:multiline_string` | `:sigil`; never mutated
  """

  defmodule Token do
    @enforce_keys [:kind, :text, :start, :stop]
    defstruct [:kind, :text, :start, :stop]
  end

  defmodule Config do
    @moduledoc "Per-language lexical rules. Multi-char operators must be listed longest-first."
    defstruct [
      :language,
      line_comments: [],
      block_comments: [],
      # {open, close, escape_or_nil}
      strings: [],
      # {open, close} without escapes
      raw_strings: [],
      multi_ops: [],
      sigils: false,
      atom_prefix: false,
      zig_multiline_strings: false,
      # Rust `'a` lifetimes/labels share a quote with `'x'` char literals —
      # an identifier run that does not end at `'` is a lifetime, not a string.
      rust_lifetimes: false,
      # Rust `r#".."#` raw strings close on `"` plus the opening `#` count.
      raw_hash_strings: false
    ]
  end

  # -- configs ---------------------------------------------------------------

  def zig_config do
    %Config{
      language: :zig,
      line_comments: ["//"],
      block_comments: [{"/*", "*/"}],
      strings: [{"\"", "\"", "\\"}, {"'", "'", "\\"}],
      multi_ops: [
        "<<=", ">>=",
        "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "->", ".*",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
        "?", ".", ":", ";", ",", "(", ")", "[", "]", "{", "}"
      ],
      zig_multiline_strings: true
    }
  end

  def elixir_config do
    %Config{
      language: :elixir,
      line_comments: ["#"],
      strings: [{"\"", "\"", "\\"}, {"'", "'", "\\"}],
      raw_strings: [{"\"\"\"", "\"\"\""}],
      multi_ops: [
        "===", "!==", "+++", "---", "&&&", "|||",
        "==", "!=", "<=", ">=", "&&", "||", "++", "--", "..", "->", "|>",
        "=>", "::", "<>",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
        "?", ".", ";", ",", "(", ")", "[", "]", "{", "}"
      ],
      sigils: true,
      atom_prefix: true
    }
  end

  def swift_config do
    %Config{
      language: :swift,
      line_comments: ["//"],
      block_comments: [{"/*", "*/"}],
      strings: [{"\"", "\"", "\\"}],
      multi_ops: [
        "<<=", ">>=", "...", "..<", "===", "!==",
        "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "->", "??", "?.", "..",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
        "?", ".", ":", ";", ",", "(", ")", "[", "]", "{", "}", "@", "#"
      ]
    }
  end

  def kotlin_config do
    %Config{
      language: :kotlin,
      line_comments: ["//"],
      block_comments: [{"/*", "*/"}],
      strings: [{"\"", "\"", "\\"}, {"'", "'", "\\"}],
      raw_strings: [{"\"\"\"", "\"\"\""}],
      multi_ops: [
        "<<=", ">>=", "...", "===", "!==",
        "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "->", "=>", "?.",
        "?:", "!!", "::", "..", "++", "--",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
        "?", ".", ":", ";", ",", "(", ")", "[", "]", "{", "}", "@", "#"
      ]
    }
  end

  def rust_config do
    %Config{
      language: :rust,
      line_comments: ["//"],
      block_comments: [{"/*", "*/"}],
      strings: [{"\"", "\"", "\\"}, {"'", "'", "\\"}],
      multi_ops: [
        "<<=", ">>=", "..=",
        "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "->", "=>", "::", "..",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~",
        "?", ".", ":", ";", ",", "(", ")", "[", "]", "{", "}", "@", "#", "$"
      ],
      rust_lifetimes: true,
      raw_hash_strings: true
    }
  end

  # -- API -------------------------------------------------------------------

  @doc """
  Lex `source` into `{tokens, line_starts}` in source order.
  """
  def lex(source, %Config{} = config) do
    tokens = lex_loop(source, 0, config, [])
    {Enum.reverse(tokens), line_starts(source)}
  end

  def line_starts(source) do
    source
    |> :binary.matches("\n")
    |> Enum.reduce([0], fn {pos, _len}, acc -> [pos + 1 | acc] end)
    |> Enum.reverse()
  end

  @doc "1-based line number of a byte offset, given `line_starts/1` output."
  def line_of(line_starts, byte_offset) do
    Enum.count(line_starts, fn start -> start <= byte_offset end)
  end

  # -- lexing loop -----------------------------------------------------------

  defp lex_loop(<<>>, _consumed, _config, acc), do: acc

  defp lex_loop(binary, consumed, config, acc) do
    case classify(binary, config) do
      {:token, kind, text, rest} ->
        stop = consumed + byte_size(text)
        token = %Token{kind: kind, text: text, start: consumed, stop: stop}
        lex_loop(rest, stop, config, [token | acc])

      {:skip, kind, rest} ->
        stop = consumed + (byte_size(binary) - byte_size(rest))
        lex_loop(rest, stop, config, [%Token{kind: :skipped, text: kind, start: consumed, stop: stop} | acc])

      :whitespace ->
        <<_, rest::binary>> = binary
        lex_loop(rest, consumed + 1, config, acc)
    end
  end

  defp classify(binary, config) do
    cond do
      ws?(binary) ->
        :whitespace

      starts_with?(binary, config.line_comments) ->
        {:skip, :comment, after_line(binary)}

      block_comment?(binary, config) ->
        {:skip, :comment, after_block_comment(binary, config)}

      raw_hash_string?(binary, config) ->
        {:skip, :raw_string, after_raw_hash(binary, config)}

      lifetime_quote?(binary, config) ->
        {:token, :op, "'", drop_prefix(binary, 1)}

      raw_string?(binary, config) ->
        {:skip, :raw_string, after_raw_string(binary, config)}

      string?(binary, config) ->
        {:skip, :string, after_string(binary, config)}

      zig_multiline?(binary, config) ->
        {:skip, :multiline_string, after_line(binary)}

      sigil?(binary, config) ->
        {:skip, :sigil, after_sigil(binary)}

      true ->
        {kind, text} = code_token(binary, config)
        rest = binary_part(binary, byte_size(text), byte_size(binary) - byte_size(text))
        {:token, kind, text, rest}
    end
  end

  defp ws?(<<c, _::binary>>) when c in ~c" \t\r\n", do: true
  defp ws?(_), do: false

  defp starts_with?(binary, prefixes), do: Enum.any?(prefixes, &String.starts_with?(binary, &1))

  defp block_comment?(binary, %Config{block_comments: pairs}) do
    Enum.any?(pairs, fn {open, _} -> String.starts_with?(binary, open) end)
  end

  defp after_block_comment(binary, %Config{block_comments: [{open, close} | _]}) do
    rest = drop_prefix(binary, byte_size(open))

    case :binary.match(rest, close) do
      :nomatch -> ""
      {pos, _} -> drop_prefix(rest, pos + byte_size(close))
    end
  end

  defp raw_string?(binary, %Config{raw_strings: pairs}) do
    Enum.any?(pairs, fn {open, _} -> String.starts_with?(binary, open) end)
  end

  # Rust lifetimes: `'a`/`'static`/`'out:` keep their quote as code; `'x'`,
  # `'\n'`, `'}'` are char literals and skip. An identifier run that ends at a
  # closing `'` is a char; anything else is a lifetime.
  defp lifetime_quote?(<<"'", rest::binary>>, %Config{rust_lifetimes: true}) do
    case rest do
      <<c, after_c::binary>>
      when c in ?a..?z or c in ?A..?Z or c == ?_ or c > 127 ->
        {_, after_run} = take_while(after_c, &lifetime_char?/1)
        not String.starts_with?(after_run, "'")

      _ ->
        false
    end
  end

  defp lifetime_quote?(_, _), do: false

  defp lifetime_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  # Rust raw strings: `r".."`, `r#".."#`, `r##".."##` (and `br..` byte-raw).
  # The close is `"` plus exactly the opening `#` count — extra `#`s are code.
  defp raw_hash_string?(binary, %Config{raw_hash_strings: true}),
    do: raw_hash_prefix(binary) != false

  defp raw_hash_string?(_, _), do: false

  defp raw_hash_prefix(<<"r", rest::binary>>), do: raw_hash_hashes(rest, 0, 1)
  defp raw_hash_prefix(<<"b", "r", rest::binary>>), do: raw_hash_hashes(rest, 0, 2)
  defp raw_hash_prefix(_), do: false

  defp raw_hash_hashes(<<"#", rest::binary>>, n, p), do: raw_hash_hashes(rest, n + 1, p + 1)
  defp raw_hash_hashes(<<"\"", _::binary>>, n, p), do: {p + 1, n}
  defp raw_hash_hashes(_, _, _), do: false

  defp after_raw_hash(binary, _config) do
    {open_len, hashes} = raw_hash_prefix(binary)
    scan_raw_close(drop_prefix(binary, open_len), hashes)
  end

  defp scan_raw_close(binary, hashes) do
    case :binary.match(binary, "\"") do
      :nomatch ->
        ""

      {pos, 1} ->
        rest = drop_prefix(binary, pos + 1)

        if String.starts_with?(rest, String.duplicate("#", hashes)) do
          drop_prefix(rest, hashes)
        else
          scan_raw_close(rest, hashes)
        end
    end
  end

  defp after_raw_string(binary, %Config{raw_strings: [{open, close} | _]}) do
    rest = drop_prefix(binary, byte_size(open))

    case :binary.match(rest, close) do
      :nomatch -> ""
      {pos, _} -> drop_prefix(rest, pos + byte_size(close))
    end
  end

  defp string?(binary, %Config{strings: triples}) do
    Enum.any?(triples, fn {open, _, _} -> String.starts_with?(binary, open) end)
  end

  defp after_string(binary, %Config{strings: triples}) do
    {open, close, escape} =
      Enum.find(triples, fn {open, _, _} -> String.starts_with?(binary, open) end)

    rest = drop_prefix(binary, byte_size(open))

    case escape do
      nil ->
        case :binary.match(rest, close) do
          :nomatch -> ""
          {pos, _} -> drop_prefix(rest, pos + byte_size(close))
        end

      esc ->
        scan_escaped(rest, :binary.first(esc), close)
    end
  end

  defp scan_escaped(<<e, _c, rest::binary>>, e, close), do: scan_escaped(rest, e, close)

  defp scan_escaped(rest, _e, close) do
    case :binary.match(rest, close) do
      :nomatch -> ""
      {pos, _} -> drop_prefix(rest, pos + byte_size(close))
    end
  end

  defp zig_multiline?(<<"\\\\", _::binary>>, %Config{zig_multiline_strings: true}), do: true
  defp zig_multiline?(_, _), do: false

  defp after_line(binary) do
    case :binary.match(binary, "\n") do
      :nomatch -> ""
      {pos, _} -> binary_part(binary, pos, byte_size(binary) - pos)
    end
  end

  defp sigil?(<<"~", c, d, _::binary>>, %Config{sigils: true})
       when c in ~c"sScCwWrRaAlLuUpPTTgG" and d in ~c"(<{[\"'/|",
       do: true

  defp sigil?(_, _), do: false

  defp after_sigil(<<"~", _letter, delim, rest::binary>>) do
    close = closing_of(delim)
    nesting? = close in [")", "]", "}"]
    skip_sigil(rest, delim, close, 1, nesting?, ?\\)
  end

  defp closing_of(?(), do: ?)
  defp closing_of(?<), do: ?>
  defp closing_of(?{), do: ?}
  defp closing_of(?[), do: ?]
  defp closing_of(d), do: d

  defp skip_sigil(<<>>, _open, _close, _depth, _nesting?, _esc), do: ""

  defp skip_sigil(<<esc, rest::binary>>, open, close, depth, nesting?, esc) do
    case rest do
      <<_c, r::binary>> -> skip_sigil(r, open, close, depth, nesting?, esc)
      <<>> -> ""
    end
  end

  defp skip_sigil(<<c, rest::binary>>, open, close, depth, nesting?, esc) do
    cond do
      <<c>> == <<close>> and depth == 1 ->
        {_, rest2} = take_while(rest, fn ch -> ch in ?a..?z or ch in ?A..?Z or ch == ?_ end)
        rest2

      <<c>> == <<close>> and depth > 1 -> skip_sigil(rest, open, close, depth - 1, nesting?, esc)
      nesting? and c == open -> skip_sigil(rest, open, close, depth + 1, nesting?, esc)
      true -> skip_sigil(rest, open, close, depth, nesting?, esc)
    end
  end

  # -- code tokens -----------------------------------------------------------

  defp code_token(binary, config) do
    <<c, _::binary>> = binary

    cond do
      ident_start?(c) ->
        {text, _} = take_while(binary, &ident_cont?/1)
        {:ident, text}

      digit?(c) ->
        {:number, lex_number(binary)}

      config.atom_prefix and c == ?: ->
        atom_token(binary)

      true ->
        op = Enum.find(config.multi_ops, &String.starts_with?(binary, &1)) || fallback_op(binary)
        {:op, op}
    end
  end

  # Numbers are kept whole so "0"/"1" sites are exact literals: int with `_`,
  # 0x/0o/0b literals, floats `1.5`/`1e+3` (the `.` only when a digit follows,
  # so `1.foo()` still lexes as number `1`, `.`, ident).
  defp lex_number(binary) do
    {digits, rest} = take_while(binary, fn ch -> digit?(ch) or ch == ?_ end)

    case rest do
      <<?x, r::binary>> when digits == "0" -> radix_digits(r, binary)
      <<?o, r::binary>> when digits == "0" -> radix_digits(r, binary)
      <<?b, r::binary>> when digits == "0" -> radix_digits(r, binary)
      <<?., d, r::binary>> when d in ?0..?9 ->
        {_frac, r2} = take_while(r, fn ch -> digit?(ch) or ch == ?_ end)
        exponent(binary, byte_size(binary) - byte_size(r2))

      _ ->
        exponent(binary, byte_size(binary) - byte_size(rest))
    end
  end

  defp radix_digits(rest, binary) do
    {_, r} = take_while(rest, fn ch -> digit?(ch) or ch in ?a..?f or ch in ?A..?F or ch == ?_ end)
    binary_part(binary, 0, byte_size(binary) - byte_size(r))
  end

  defp exponent(binary, len) do
    case binary_part(binary, len, byte_size(binary) - len) do
      <<e, _::binary>> when e in ~c"eE" ->
        rest = binary_part(binary, len, byte_size(binary) - len)
        {_, after_e} = take_while(rest, fn ch -> ch in ~c"eE+-" or digit?(ch) end)

        case after_e do
          <<d, _::binary>> when d in ?0..?9 ->
            {_, r} = take_while(after_e, fn ch -> digit?(ch) or ch == ?_ end)
            binary_part(binary, 0, byte_size(binary) - byte_size(r))

          _ ->
            binary_part(binary, 0, len)
        end

      _ ->
        binary_part(binary, 0, len)
    end
  end

  defp fallback_op(<<c, _::binary>>) when c in ~c"+-*/=<>&|^~%.!", do: <<c>>
  defp fallback_op(<<c, _::binary>>) when c in ~c"()[]{};,:?@#", do: <<c>>
  defp fallback_op(binary), do: String.first(binary)

  defp ident_start?(c), do: c in ?a..?z or c in ?A..?Z or c == ?_ or c > 127
  defp ident_cont?(c), do: ident_start?(c) or digit?(c) or c in ~c"?!"
  defp digit?(c), do: c in ?0..?9

  defp atom_token(<<?:, rest::binary>>) do
    case rest do
      <<c, _::binary>> when c in ~c"\"'" ->
        r = quoted_rest(rest, c, ?\\)
        text = binary_part(rest, 0, byte_size(rest) - byte_size(r))
        {:atom_op, ":" <> text}

      <<c, _::binary>> when c in ~c"+-*/=<>&|^~%.!<>@" ->
        {text, _} = take_while(rest, fn ch -> ch in ~c"+-*/=<>&|^~%.!<>@" end)
        {:atom_op, ":" <> text}

      _ ->
        {text, _} = take_while(rest, &ident_cont?/1)
        {:atom_op, ":" <> text}
    end
  end

  defp quoted_rest(<<>>, _q, _esc), do: ""

  defp quoted_rest(<<esc, _c, rest::binary>>, q, esc), do: quoted_rest(rest, q, esc)
  defp quoted_rest(<<q, rest::binary>>, q, _esc), do: rest
  defp quoted_rest(<<_, rest::binary>>, q, esc), do: quoted_rest(rest, q, esc)

  defp take_while(binary, fun) do
    n = count_while(binary, fun, 0)
    {binary_part(binary, 0, n), binary_part(binary, n, byte_size(binary) - n)}
  end

  defp count_while(<<c, rest::binary>>, fun, n) do
    if fun.(c), do: count_while(rest, fun, n + 1), else: n
  end

  defp count_while(<<>>, _fun, n), do: n



  defp drop_prefix(binary, n), do: binary_part(binary, n, byte_size(binary) - n)
end
