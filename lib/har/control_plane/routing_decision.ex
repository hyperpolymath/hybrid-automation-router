defmodule HAR.ControlPlane.RoutingDecision do
  @moduledoc """
  Represents a routing decision for a single operation.
  """

  alias HAR.Semantic.Operation

  @type t :: %__MODULE__{
          operation: Operation.t(),
          backend: map(),
          alternatives: [map()],
          reason: atom(),
          timestamp: DateTime.t()
        }

  defstruct [
    :operation,
    :backend,
    :alternatives,
    :reason,
    :timestamp
  ]
end
