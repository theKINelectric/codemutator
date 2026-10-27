defmodule Mutator.Languages.JavaScript do
  @moduledoc """
  Explicit JavaScript/TypeScript Node-test execution profile. A package.json
  alone never opts a polyglot project into mutation execution. JSON profile
  data selects source and tests; operator-controlled settings select tools.
  """
  @behaviour Mutator.Languages.Adapter
  @profile ".codemutator.json"
  @extensions ~w(.js .jsx .mjs .cjs .ts .tsx .mts .cts)
  @excluded ~w(test tests spec __tests__ fixtures vendor node_modules deps _build build dist target coverage .git .hg .next .nuxt .svelte-kit)
  @sentinel "CODEMUTATOR_JS_RESULT "

  @impl true
  def id, do: :javascript
  @impl true
  def name, do: "JavaScript / TypeScript"
  @impl true
  def markers, do: [@profile]
  @impl true
  def source_extensions, do: @extensions
  @impl true
  def detect(root) do
    if File.exists?(Path.join(root, @profile)) do
      case read_profile(root) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :no_codemutator_profile}
    end
  end

  def read_profile(root) do
    with {:ok, %{type: :regular, size: size}} when size <= 65_536 <-
           File.lstat(Path.join(root, @profile)),
         {:ok, bytes} <- File.read(Path.join(root, @profile)),
         {:ok, value} <- Jason.decode(bytes),
         :ok <- validate_profile(value) do
      {:ok, value}
    else
      {:error, {:invalid_javascript_profile, _}} = error ->
        error

      _ ->
        {:error,
         {:invalid_javascript_profile, "expected a regular JSON profile, schemaVersion 1"}}
    end
  end

  defp validate_profile(value) do
    valid =
      keys?(value, ~w(schemaVersion language runner typecheck source)) and
        value["schemaVersion"] == 1 and value["language"] == "javascript-typescript" and
        keys?(value["runner"], ~w(kind files)) and value["runner"]["kind"] == "node-test" and
        paths?(value["runner"]["files"], true, false) and
        Enum.all?(
          value["runner"]["files"],
          &(Path.extname(&1) in ~w(.js .mjs .cjs .ts .mts .cts))
        ) and
        typecheck?(value["typecheck"]) and keys?(value["source"], ~w(include exclude)) and
        paths?(value["source"]["include"], true, true) and
        paths?(value["source"]["exclude"], false, true)

    if valid,
      do: :ok,
      else:
        {:error,
         {:invalid_javascript_profile,
          "unsupported profile fields, version, runner or relative paths"}}
  end

  defp keys?(value, expected),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(expected)

  defp typecheck?(%{"kind" => "none"} = value), do: keys?(value, ["kind"])

  defp typecheck?(%{"kind" => "typescript", "project" => project} = value),
    do: keys?(value, ~w(kind project)) and safe_path?(project, false)

  defp typecheck?(_), do: false

  defp paths?(values, nonempty, glob) do
    is_list(values) and (not nonempty or values != []) and length(values) <= 1_000 and
      Enum.all?(values, &safe_path?(&1, glob))
  end

  defp safe_path?(path, glob) when is_binary(path) do
    path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", "\0", ":", "[", "]", "{", "}"]) and
      not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) and
      (glob or not String.contains?(path, ["*", "?"]))
  end

  defp safe_path?(_, _), do: false

  def mutable_files(root, scope \\ nil) do
    case read_profile(root) do
      {:ok, profile} ->
        source = profile["source"]

        walk(root, "")
        |> Enum.filter(fn rel ->
          source_path?(rel) and in_scope?(rel, scope) and
            Enum.any?(source["include"], &glob?(&1, rel)) and
            not Enum.any?(source["exclude"], &glob?(&1, rel))
        end)
        |> Enum.sort()

      {:error, reason} ->
        raise ArgumentError, "JavaScript profile discovery failed: #{inspect(reason)}"
    end
  end

  defp walk(root, rel) do
    case File.ls(Path.join(root, rel)) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = if rel == "", do: entry, else: Path.join(rel, entry)

          case File.lstat(Path.join(root, path)) do
            {:ok, %{type: :directory}} -> if entry in @excluded, do: [], else: walk(root, path)
            {:ok, %{type: :regular}} -> [path]
            _ -> []
          end
        end)

      {:error, reason} ->
        raise ArgumentError, "JavaScript source directory is unreadable: #{inspect(reason)}"
    end
  end

  defp source_path?(rel) do
    Path.extname(rel) in @extensions and
      not Regex.match?(~r/\.(?:test|spec)\.[^\/]+$|\.d\.(?:ts|mts|cts)$/, rel)
  end

  defp in_scope?(_rel, scope) when scope in [nil, ""], do: true

  defp in_scope?(rel, scope) do
    prefix = scope |> String.trim_leading("/") |> String.trim_trailing("/")
    rel == prefix or String.starts_with?(rel, prefix <> "/")
  end

  defp glob?(pattern, rel) do
    expression = glob_expression(String.split(pattern, "/"))
    Regex.match?(Regex.compile!("\\A" <> expression <> "\\z"), rel)
  end

  defp glob_expression([]), do: ""
  defp glob_expression(["**"]), do: "(?:[^/.][^/]*(?:/[^/.][^/]*)*)?"
  defp glob_expression(["**" | rest]), do: "(?:[^/.][^/]*/)*" <> glob_expression(rest)

  defp glob_expression([segment | rest]) do
    prefix = if String.starts_with?(segment, "."), do: "", else: "(?!\\.)"

    expression =
      segment |> Regex.escape() |> String.replace("\\*", "[^/]*") |> String.replace("\\?", "[^/]")

    prefix <> expression <> if(rest == [], do: "", else: "/" <> glob_expression(rest))
  end

  @impl true
  def preflight(subject_root, worker) do
    with {:ok, profile} <- read_profile(subject_root),
         {:ok, ^profile} <- read_profile(worker.project),
         :ok <- no_symlinks(worker.project),
         {:ok, node} <- node_toolchain(),
         {:ok, compiler_args} <- compiler_args(profile, worker),
         {:ok, facts} <- JsTsParser.parse("", "preflight.js") do
      script = Application.app_dir(:mutator, "priv/js_ts_runner/bin/runner.mjs")

      if File.regular?(script) do
        parser =
          Map.take(facts["meta"], ~w(parser parser_version package_version))
          |> Map.put("policy", facts["policy"])

        metadata = %{
          "profile" => profile,
          "profile_sha256" =>
            Mutator.Scanner.file_hash(File.read!(Path.join(subject_root, @profile))),
          "parser" => parser
        }

        {:ok,
         %{
           argv:
             [
               node,
               script,
               "--worker",
               Path.expand(worker.project),
               "--timeout",
               "600000",
               "--service-owned-group"
             ] ++
               compiler_args,
           env: %{"HOME" => worker.home, "NODE_OPTIONS" => "", "NODE_PATH" => ""},
           metadata: metadata
         }}
      else
        {:error, :javascript_runner_unavailable}
      end
    else
      {:ok, _} -> {:error, {:invalid_javascript_profile, "worker profile differs from snapshot"}}
      {:error, _} = error -> error
    end
  end

  defp node_toolchain do
    configured =
      Application.get_env(:mutator, :javascript_node) || System.get_env("CODEMUTATOR_NODE") ||
        "node"

    case System.find_executable(configured) do
      nil ->
        {:error, :toolchain_unavailable}

      node ->
        case System.cmd(node, ["--version"],
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             ) do
          {version, 0} ->
            case Version.parse(version |> String.trim() |> String.trim_leading("v")) do
              {:ok, parsed} ->
                if Version.compare(parsed, Version.parse!("26.6.0")) != :lt and parsed.major == 26,
                  do: {:ok, node},
                  else: {:error, :unsupported_node_runtime}

              _ ->
                {:error, :unsupported_node_runtime}
            end

          _ ->
            {:error, :toolchain_unavailable}
        end
    end
  rescue
    _ -> {:error, :toolchain_unavailable}
  end

  defp compiler_args(%{"typecheck" => %{"kind" => "none"}}, _worker), do: {:ok, []}

  defp compiler_args(_profile, worker) do
    compiler =
      Application.get_env(:mutator, :javascript_tsc) || System.get_env("CODEMUTATOR_TSC") ||
        Path.join(worker.project, "node_modules/typescript/lib/tsc.js")

    if is_binary(compiler) and Path.type(compiler) == :absolute and File.regular?(compiler),
      do: {:ok, ["--compiler", compiler]},
      else: {:error, :missing_compiler}
  end

  defp no_symlinks(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          path = Path.join(root, entry)

          result =
            case File.lstat(path) do
              {:ok, %{type: :symlink}} -> {:error, :unsupported_workspace_symlink}
              {:ok, %{type: :directory}} -> no_symlinks(path)
              {:ok, _} -> :ok
              {:error, _} -> {:error, :workspace_unreadable}
            end

          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
        end)

      _ ->
        {:error, :workspace_unreadable}
    end
  end

  def result_metadata(tail) when is_binary(tail) and byte_size(tail) <= 8_000 do
    with line when is_binary(line) <- tail |> String.split("\n", trim: true) |> List.last(),
         true <- String.starts_with?(line, @sentinel),
         {:ok, %{"protocol" => 1, "status" => status, "reason" => reason} = value} <-
           Jason.decode(
             binary_part(line, byte_size(@sentinel), byte_size(line) - byte_size(@sentinel))
           ),
         true <- metadata_shape?(value),
         true <- valid_result?(status, reason, value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_javascript_result}
    end
  end

  def result_metadata(_), do: {:error, :invalid_javascript_result}

  defp metadata_shape?(value) do
    Enum.all?(
      Map.keys(value),
      &(&1 in ~w(protocol status reason phase tests runtime compilerDiagnostics message))
    ) and
      (not Map.has_key?(value, "phase") or value["phase"] in ~w(worker baseline mutant)) and
      (not Map.has_key?(value, "message") or
         (is_binary(value["message"]) and byte_size(value["message"]) <= 500)) and
      (not Map.has_key?(value, "tests") or tests_shape?(value["tests"])) and
      (not Map.has_key?(value, "runtime") or runtime_shape?(value["runtime"])) and
      (not Map.has_key?(value, "compilerDiagnostics") or
         diagnostics_shape?(value["compilerDiagnostics"]))
  end

  defp tests_shape?(%{"executed" => count, "counts" => counts} = value) do
    keys?(value, ~w(executed counts)) and is_integer(count) and count >= 0 and
      count <= 1_000_000_000 and
      (is_nil(counts) or
         (is_map(counts) and
            Enum.all?(counts, fn {key, n} ->
              key in ~w(tests failed passed cancelled skipped todo topLevel suites) and
                is_integer(n) and n >= 0 and n <= 1_000_000_000
            end)))
  end

  defp tests_shape?(_), do: false

  defp runtime_shape?(%{"node" => version} = value) do
    Enum.all?(Map.keys(value), &(&1 in ~w(node compiler))) and is_binary(version) and
      Regex.match?(~r/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, version) and
      (not Map.has_key?(value, "compiler") or compiler_shape?(value["compiler"]))
  end

  defp runtime_shape?(_), do: false

  defp compiler_shape?(%{"name" => "typescript", "version" => version} = value),
    do:
      keys?(value, ~w(name version)) and is_binary(version) and
        Regex.match?(~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, version)

  defp compiler_shape?(_), do: false

  defp diagnostics_shape?(values),
    do:
      is_list(values) and length(values) <= 8 and
        Enum.all?(values, fn
          %{"code" => code, "message" => message} = value ->
            keys?(value, ~w(code message)) and is_integer(code) and code > 0 and
              is_binary(message) and byte_size(message) <= 720

          _ ->
            false
        end)

  defp valid_result?(status, nil, value) when status in ["passed", "survived"] do
    match?(
      %{
        "tests" => %{
          "executed" => n,
          "counts" => %{"passed" => p, "failed" => 0, "cancelled" => 0}
        },
        "runtime" => %{"node" => version}
      }
      when is_integer(n) and n > 0 and is_integer(p) and p > 0 and is_binary(version),
      value
    )
  end

  defp valid_result?("killed", reason, _), do: reason in ~w(assertion runtime_crash timeout)
  defp valid_result?("invalid", reason, _), do: reason in ~w(typecheck syntax)
  defp valid_result?("error", reason, _), do: is_binary(reason) and byte_size(reason) <= 128
  defp valid_result?(_, _, _), do: false

  @impl true
  def classify({:timeout, _}), do: {:killed, :timeout}

  def classify({:ok, %{exit_code: code, tail: tail}}) do
    case result_metadata(tail) do
      {:ok, %{"status" => status}} when code == 0 and status in ["passed", "survived"] ->
        :survived

      {:ok, %{"status" => "invalid"}} when code == 20 ->
        :invalid

      {:ok, %{"status" => "killed", "reason" => "assertion"}} when code == 21 ->
        {:killed, :assertion}

      {:ok, %{"status" => "killed", "reason" => "runtime_crash"}} when code == 21 ->
        {:killed, :runtime_crash}

      {:ok, %{"status" => "killed", "reason" => "timeout"}} when code == 21 ->
        {:killed, :timeout}

      _ ->
        :unclassified
    end
  end
end
