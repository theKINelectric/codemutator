defmodule Mutator.Languages.Detector do
  @moduledoc """
  Detect the language of a subject directory by its root markers. Detection
  is separate from execution capability (MVP_PLAN.md §2): the detector
  reports what the project *is*; the adapter's preflight reports whether we
  can *run* it here.
  """

  @adapters [Mutator.Languages.Zig, Mutator.Languages.ElixirLang, Mutator.Languages.Swift, Mutator.Languages.Kotlin]

  def adapters, do: @adapters

  @doc """
  Returns `{:ok, adapter}` for the subject's language, or
  `{:error, {:unsupported, found}}` listing what was matched (if any).
  """
  def detect(subject_root) do
    matches =
      Enum.filter(@adapters, fn adapter ->
        adapter.detect(subject_root) == :ok
      end)

    case matches do
      [adapter | []] -> {:ok, adapter}
      [] -> {:error, :no_language_detected}
      many -> {:error, {:ambiguous, Enum.map(many, & &1.id())}}
    end
  end

  @doc """
  Files under the subject that this language mutates (relative paths).
  `scope` is an optional path-substring filter from the submit form.
  """
  def mutable_files(adapter, subject_root, scope \\ nil) do
    exts = adapter.source_extensions()

    subject_root
    |> walk("")
    |> Enum.filter(fn rel ->
      Path.extname(rel) in exts and not excluded_path?(rel) and not build_script?(adapter, rel) and
        in_scope?(rel, scope)
    end)
    |> Enum.sort()
  end

  # `scope` is a leading-path filter ("src/"), never a substring: subjects
  # like honey_badger carry experiments/ with thousands of nested source
  # copies whose paths contain "src/" too.
  defp in_scope?(_rel, nil), do: true
  defp in_scope?(_rel, ""), do: true

  defp in_scope?(rel, scope) do
    prefix = scope |> String.trim_leading("/") |> then(&if String.ends_with?(&1, "/"), do: &1, else: &1 <> "/")
    String.starts_with?(rel, prefix) or rel == String.trim_trailing(prefix, "/")
  end

  # Build scripts are project configuration, not subject code: mutating
  # build.zig perturbs every mutant's compile instead of testing behavior.
  defp build_script?(Mutator.Languages.Zig, rel), do: rel in ["build.zig"]
  defp build_script?(_adapter, _rel), do: false

  # Vendored/generated/build directories are copied but never mutated.
  @excluded_dirs [
    "test", "tests", "spec", "vendor", "node_modules", "deps", "_build",
    "zig-out", ".zig-cache", "build", "dist", "target", ".build", ".git",
    "fixtures", "test/fixtures"
  ]

  defp excluded_path?(rel) do
    parts = Path.split(rel)
    Enum.any?(parts, &(&1 in @excluded_dirs))
  end

  defp walk(root, rel) do
    dir = Path.join(root, rel)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          rel_entry = if rel == "", do: entry, else: Path.join(rel, entry)
          path = Path.join(root, rel_entry)

          cond do
            File.dir?(path) -> walk(root, rel_entry)
            true -> [rel_entry]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
