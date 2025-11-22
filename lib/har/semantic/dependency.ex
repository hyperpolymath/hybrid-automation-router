defmodule HAR.Semantic.Dependency do
  @moduledoc """
  Represents a dependency relationship between two operations.

  Dependencies encode execution ordering, requirements, and notifications
  between infrastructure operations.
  """

  @type dependency_type ::
          :sequential
          | :requires
          | :notifies
          | :watches
          | :conflicts
          | :depends_on
          | atom()

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          type: dependency_type(),
          metadata: map()
        }

  defstruct [
    :from,
    :to,
    :type,
    :metadata
  ]

  @doc """
  Create a new dependency between operations.

  ## Examples

      iex> Dependency.new("op1", "op2", :requires)
      %Dependency{from: "op1", to: "op2", type: :requires}
  """
  def new(from_id, to_id, type, opts \\ []) do
    %__MODULE__{
      from: from_id,
      to: to_id,
      type: type,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Check if dependency creates a valid ordering constraint.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{from: from, to: to}) when is_binary(from) and is_binary(to) do
    from != to
  end

  def valid?(_), do: false
end
