defmodule Mutator.Languages.Kotlin do
  @moduledoc """
  Kotlin adapter: detection and capability reporting only. No Kotlin/JDK
  toolchain is installed on this host, and MVP_PLAN.md §1 requires Kotlin to
  report `toolchain_unavailable` explicitly rather than pretend to execute.
  """

  @behaviour Mutator.Languages.Adapter

  @impl true
  def id, do: :kotlin
  @impl true
  def name, do: "Kotlin"
  @impl true
  def markers, do: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
  @impl true
  def source_extensions, do: [".kt", ".kts"]

  @impl true
  def detect(subject_root) do
    if Enum.any?(markers(), &File.exists?(Path.join(subject_root, &1))) do
      :ok
    else
      {:error, :no_gradle_project}
    end
  end

  @impl true
  def preflight(_subject_root, _worker), do: {:error, :toolchain_unavailable}

  @impl true
  def classify(_), do: :unclassified
end
