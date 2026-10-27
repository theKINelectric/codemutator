defmodule Mutator.Scanner.JavaScript do
  @moduledoc "Shared AST facts mapped to byte-verified mutation sites. No subject execution."
  alias Mutator.Scanner
  alias Mutator.Scanner.Site

  def scan(rel_path, source) do
    unless is_binary(rel_path) and rel_path != "" and Path.type(rel_path) == :relative and
             not String.contains?(rel_path, ["\\", "\0"]) and
             not Enum.any?(String.split(rel_path, "/"), &(&1 in ["", ".", ".."])) do
      raise ArgumentError, "JavaScript scanner requires a relative source path"
    end

    case JsTsParser.parse(source, rel_path) do
      {:ok, facts} ->
        Enum.map(facts["sites"], &site(&1, rel_path, source, facts["source_sha256"]))

      {:error, reason} ->
        raise ArgumentError, "JavaScript/TypeScript parser failed: #{inspect(reason)}"
    end
  end

  defp site(value, file, source, file_hash) do
    original = binary_part(source, value["byte_start"], value["byte_end"] - value["byte_start"])

    if original != value["original"] or Scanner.file_hash(source) != file_hash,
      do: raise(ArgumentError, "JavaScript parser source custody mismatch")

    operator = category(value["operator"])

    key =
      Jason.encode!([
        file,
        file_hash,
        value["byte_start"],
        value["byte_end"],
        operator,
        original,
        value["replacement"]
      ])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    %Site{
      file: file,
      function: value["function"],
      function_line: value["function_start"],
      function_end_line: value["function_end"],
      line: value["line"],
      byte_start: value["byte_start"],
      byte_end: value["byte_end"],
      operator: operator,
      original: original,
      replacement: value["replacement"],
      site_key: key,
      file_hash: file_hash
    }
  end

  defp category(value) when value in ~w(< <= > >=), do: "comparison"
  defp category(value) when value in ~w(== != === !==), do: "equality"
  defp category(value) when value in ~w(+ - * /), do: "arith"
  defp category(value) when value in ~w(&& ||), do: "logical"
  defp category("boolean"), do: "bool"
  defp category("number"), do: "const01"
  defp category("!"), do: "unary_del"
end
