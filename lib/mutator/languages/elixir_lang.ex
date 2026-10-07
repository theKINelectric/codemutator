defmodule Mutator.Languages.ElixirLang do
  @moduledoc """
  Elixir adapter. Root `mix.exs`; `MIX_ENV=test mix test`. Ordinary Mix
  projects only for the MVP.
  """

  @behaviour Mutator.Languages.Adapter

  @impl true
  def id, do: :elixir
  @impl true
  def name, do: "Elixir"
  @impl true
  def markers, do: ["mix.exs"]
  @impl true
  def source_extensions, do: [".ex"]

  @impl true
  def detect(subject_root) do
    if File.exists?(Path.join(subject_root, "mix.exs")) do
      :ok
    else
      {:error, :no_mix_exs}
    end
  end

  @impl true
  def preflight(subject_root, worker) do
    with {:ok, mix} <- find_mix(subject_root) do
      {:ok,
       %{
         argv: [mix, "test", "--color"],
         env: %{
           "MIX_ENV" => "test",
           "HOME" => worker.home,
           "MIX_BUILD_PATH" => "_build"
         }
       }}
    end
  end

  @impl true
  def classify({:timeout, _}), do: {:killed, :timeout}
  def classify({:ok, %{exit_code: 0}}), do: :survived

  def classify({:ok, %{exit_code: _, tail: tail}}) do
    cond do
      tail =~ "error:" and (tail =~ ".ex:" or tail =~ "Compilation error") -> :invalid
      tail =~ "test failures" or tail =~ "Assertion with" or tail =~ "assert" ->
        {:killed, :assertion}

      true -> :unclassified
    end
  end

  defp find_mix(_subject_root) do
    case System.find_executable("mix") do
      nil -> {:error, :toolchain_unavailable}
      mix -> {:ok, mix}
    end
  end
end
