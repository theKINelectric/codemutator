defmodule Mutator.Repo do
  use Ecto.Repo,
    otp_app: :mutator,
    adapter: Ecto.Adapters.SQLite3
end
