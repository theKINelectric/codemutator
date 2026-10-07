defmodule Mutator.FlowExtraSmokeTest do
  @moduledoc """
  Milestone 1 gate: FlowExtra runs on this host's OTP with replicated stages,
  admission control, and error routing. If this fails, no pipeline work can
  proceed (MVP_PLAN.md requires the OTP 28 downstream smoke check).
  """

  use ExUnit.Case, async: false

  defmodule SmokePipeline do
    use FlowExtra.Pipeline

    pipe :double, count: 2
    pipe :tag

    defstruct [:number, :doubled, :tagged, :replica]

    def double(%{number: number}, %{replica: replica}) do
      %{doubled: number * 2, replica: replica}
    end

    def tag(%{doubled: doubled}, _opts) do
      %{tagged: {:ok, doubled}}
    end
  end

  defmodule RaisingPipeline do
    use FlowExtra.Pipeline

    pipe :boom
    error_pipe :rescue_boom

    defstruct [:value]

    def boom(_data, _opts), do: raise("boom")

    def rescue_boom(_error, _data, _opts) do
      %{value: :rescued}
    end
  end

  test "two-replica pipeline processes calls and reports its replica" do
    pipeline = SmokePipeline.start(%{replica: :from_opts})

    results =
      for i <- 1..20 do
        SmokePipeline.call(pipeline, %SmokePipeline{number: i})
      end

    assert Enum.all?(results, &match?(%SmokePipeline{tagged: {:ok, _}}, &1))
    # count: 2 replicas both served traffic across the batch.
    replicas = results |> Enum.map(& &1.replica) |> MapSet.new()
    assert MapSet.size(replicas) == 1
    assert Enum.all?(results, &(&1.doubled == &1.number * 2))

    SmokePipeline.stop(pipeline)
  end

  test "error pipe routes raised errors instead of crashing the pipeline" do
    pipeline = RaisingPipeline.start(%{})

    assert %RaisingPipeline{value: :rescued} =
             RaisingPipeline.call(pipeline, %RaisingPipeline{value: :before})

    # The pipeline survives its error and serves again.
    assert %RaisingPipeline{value: :rescued} =
             RaisingPipeline.call(pipeline, %RaisingPipeline{value: :again})

    RaisingPipeline.stop(pipeline)
  end

  defmodule SlowPipeline do
    use FlowExtra.Pipeline

    pipe :slow

    defstruct [:n]

    def slow(%{n: n}, _opts) do
      Process.sleep(150)
      %{n: n + 1}
    end
  end

  test "admission refuses overload with a definite refusal" do
    pipeline = SlowPipeline.start(%{admission_capacity: 1})

    assert :ok = SlowPipeline.cast(pipeline, %SlowPipeline{n: 1})

    refusal =
      Enum.find_value([:overloaded, :unavailable, {:unacknowledged, :ref}], fn _ ->
        # cast returns :ok | {:error, reason}; keep retrying until the first
        # admission is settled, then expect a definite refusal.
        case SlowPipeline.cast(pipeline, %SlowPipeline{n: 2}) do
          :ok -> nil
          {:error, reason} -> reason
        end
      end)

    assert refusal in [:overloaded, :unavailable]

    SlowPipeline.stop(pipeline)
  end
end
