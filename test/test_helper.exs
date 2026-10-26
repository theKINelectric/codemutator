# e2e compiles zig mutants against a fixture subject (slow, toolchain-bound):
# opt in with `mix test --include e2e`, excluded by default.
ExUnit.start(exclude: [:e2e])
Ecto.Adapters.SQL.Sandbox.mode(Mutator.Repo, :manual)
