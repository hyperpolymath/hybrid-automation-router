defmodule HAR.ControlPlane.RoutingPlan do
  @moduledoc """
  Complete routing plan for a semantic graph.
  """

  alias HAR.Semantic.Graph
  alias HAR.ControlPlane.RoutingDecision

  @type t :: %__MODULE__{
          graph: Graph.t(),
          decisions: [RoutingDecision.t()],
          target: atom(),
          metadata: map()
        }

  defstruct [
    :graph,
    :decisions,
    :target,
    :metadata
  ]
end
