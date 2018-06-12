defmodule Kiq.Queue.Producer do
  @moduledoc false

  use GenStage

  @behaviour GenStage

  alias Kiq.Client

  defmodule State do
    @moduledoc false

    @enforce_keys [:client, :queue]
    defstruct client: nil, demand: 0, poll_interval: 1_000, queue: nil
  end

  @doc false
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    GenStage.start_link(__MODULE__, opts, name: name)
  end

  # Server

  @impl GenStage
  def init(opts) do
    state = struct(State, opts)

    schedule_poll(state)
    schedule_resurrect(state)

    {:producer, state}
  end

  @impl GenStage
  def handle_info(_message, %State{demand: 0} = state) do
    {:noreply, [], state}
  end

  def handle_info(:poll, %State{client: client, demand: demand, queue: queue} = state) do
    schedule_poll(state)

    count = Client.queue_size(client, queue)

    dispatch(%{state | demand: demand + count})
  end

  def handle_info(:resurrect, %State{client: client, queue: queue} = state) do
    :ok = Client.resurrect(client, queue)

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_demand(demand, %State{demand: buffered_demand} = state) do
    schedule_poll(state)

    dispatch(%{state | demand: demand + buffered_demand})
  end

  # Helpers

  defp dispatch(%State{client: client, demand: demand, queue: queue} = state) do
    jobs = Client.dequeue(client, queue, demand)

    {:noreply, jobs, %{state | demand: demand - length(jobs)}}
  end

  defp jitter(interval) do
    trunc((interval / 2) + (interval * :rand.uniform()))
  end

  defp schedule_poll(%State{poll_interval: interval}) do
    Process.send_after(self(), :poll, jitter(interval))
  end

  defp schedule_resurrect(%State{poll_interval: interval}) do
    Process.send_after(self(), :resurrect, jitter(interval))
  end
end