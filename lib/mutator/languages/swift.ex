defmodule Mutator.Languages.Swift do
  @moduledoc """
  Swift adapter. SwiftPM `Package.swift`; `swift test`. Xcode-only projects
  are declined clearly.
  """

  @behaviour Mutator.Languages.Adapter

  @impl true
  def id, do: :swift
  @impl true
  def name, do: "Swift"
  @impl true
  def markers, do: ["Package.swift"]
  @impl true
  def source_extensions, do: [".swift"]

  @impl true
  def detect(subject_root) do
    cond do
      File.exists?(Path.join(subject_root, "Package.swift")) -> :ok
      File.exists?(Path.join(subject_root, "*.xcodeproj")) -> {:error, :xcode_project_unsupported}
      true -> {:error, :no_package_swift}
    end
  end

  @impl true
  def preflight(_subject_root, worker) do
    case System.find_executable("swift") do
      nil ->
        {:error, :toolchain_unavailable}

      swift ->
        {:ok,
         %{
           argv: [swift, "test", "--scratch-path", Path.join(worker.scratch, ".build")],
           env: %{"HOME" => worker.home}
         }}
    end
  end

  @impl true
  def classify({:timeout, _}), do: {:killed, :timeout}
  def classify({:ok, %{exit_code: 0}}), do: :survived

  def classify({:ok, %{exit_code: _, tail: tail}}) do
    cond do
      tail =~ "error:" and not (tail =~ "XCTAssert") -> :invalid
      tail =~ "failed" or tail =~ "XCTAssert" -> {:killed, :assertion}
      tail =~ "Fatal error" or tail =~ "crashed" -> {:killed, :runtime_crash}
      true -> :unclassified
    end
  end
end
