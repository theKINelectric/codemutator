defmodule MutatorWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use MutatorWeb, :controller` and
  `use MutatorWeb, :live_view`.
  """
  use MutatorWeb, :html

  embed_templates "layouts/*"
end
