defmodule HAR.DataPlane.Supervisor do
  @moduledoc """
  Supervisor for data plane components.

  Manages parsers, transformers, and graph cache.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Data plane components are stateless, no persistent GenServers needed
    # Parsers and transformers are called directly

    children = [
      # TODO: Add graph cache, validation engine
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
