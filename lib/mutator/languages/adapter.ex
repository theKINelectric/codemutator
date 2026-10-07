defmodule Mutator.Languages.Adapter do
  @moduledoc """
  The per-language boundary (MVP_PLAN.md §2). Detection is separate from
  execution capability: a language can be detected but report its toolchain
  unavailable (Kotlin until a JDK/Gradle profile is qualified).
  """

  @type run_result ::
          {:ok, %{exit_code: non_neg_integer, elapsed_ms: integer, tail: binary}}
          | {:timeout, %{elapsed_ms: integer, tail: binary}}

  @callback id :: atom()
  @callback name :: String.t()
  @callback markers :: [String.t()]
  @callback source_extensions :: [String.t()]
  @callback detect(subject_root :: Path.t()) :: :ok | {:error, term()}
  @doc """
  Resolve the toolchain for a subject. Returns the test argv (absolute
  executables) plus any extra env (private caches, HOME) or
  `{:error, :toolchain_unavailable}`.
  """
  @callback preflight(subject_root :: Path.t(), worker :: map()) ::
              {:ok, %{argv: [String.t()], env: %{optional(String.t()) => String.t()}}}
              | {:error, :toolchain_unavailable | term()}
  @doc """
  Classify a finished run into a mutation outcome status:
  `:survived | {:killed, :assertion | :runtime_crash | :timeout} | :invalid |
  :unclassified`.
  """
  @callback classify(result :: run_result()) ::
              :survived
              | {:killed, :assertion | :runtime_crash | :timeout}
              | :invalid
              | :unclassified
end
