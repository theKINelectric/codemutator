defmodule MutatorWeb.RunComponents do
  @moduledoc "Small presentational components for run views."
  use Phoenix.Component

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :emphasis, :boolean, default: false

  def stat(assigns) do
    ~H"""
    <div class={"rounded-lg border border-slate-200 bg-white px-4 py-3 #{if @emphasis, do: "ring-1 ring-sky-300", else: ""}"}>
      <div class="text-xs uppercase tracking-wide text-slate-500"><%= @label %></div>
      <div class="mt-0.5 text-lg font-semibold text-slate-900"><%= @value %></div>
    </div>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    class =
      case assigns.status do
        "killed" -> "text-rose-700 bg-rose-50"
        "survived" -> "text-emerald-700 bg-emerald-50"
        "invalid" -> "text-slate-600 bg-slate-100"
        "error" -> "text-amber-700 bg-amber-50"
        _ -> "text-slate-500 bg-slate-50"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"rounded px-1.5 py-0.5 text-xs font-medium #{@class}"}><%= @status %></span>
    """
  end
end
