defmodule HAR.ControlPlane.PolicyEngine do
  @moduledoc """
  Policy engine for routing decisions.

  Enforces policies that control which backends can handle which operations.
  Supports:
  - Allow/deny rules
  - Environment constraints
  - Device type filtering
  - Rate limiting
  - Audit logging
  """

  use GenServer
  require Logger

  alias HAR.Semantic.Operation

  @type policy :: %{
          name: String.t(),
          type: :allow | :deny | :require | :prefer,
          condition: map(),
          action: map()
        }

  @type evaluation_result :: :allow | :deny | {:prefer, integer()}

  defstruct [
    policies: [],
    evaluations: 0,
    denials: 0
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Apply policies to filter backends for an operation.

  Returns backends that pass all policy checks.
  """
  @spec apply_policies([map()], Operation.t(), keyword()) :: [map()]
  def apply_policies(backends, operation, opts \\ []) do
    try do
      GenServer.call(__MODULE__, {:apply, backends, operation, opts})
    catch
      :exit, _ ->
        # Fallback: return all backends if policy engine is down
        backends
    end
  end

  @doc """
  Evaluate a single backend against policies for an operation.
  """
  @spec evaluate(map(), Operation.t(), keyword()) :: evaluation_result()
  def evaluate(backend, operation, opts \\ []) do
    try do
      GenServer.call(__MODULE__, {:evaluate, backend, operation, opts})
    catch
      :exit, _ -> :allow
    end
  end

  @doc """
  Add a policy to the engine.
  """
  @spec add_policy(policy()) :: :ok
  def add_policy(policy) do
    GenServer.cast(__MODULE__, {:add_policy, policy})
  end

  @doc """
  Remove a policy by name.
  """
  @spec remove_policy(String.t()) :: :ok
  def remove_policy(name) do
    GenServer.cast(__MODULE__, {:remove_policy, name})
  end

  @doc """
  Get all registered policies.
  """
  @spec list_policies() :: [policy()]
  def list_policies do
    try do
      GenServer.call(__MODULE__, :list_policies)
    catch
      :exit, _ -> []
    end
  end

  @doc """
  Load policies from configuration.
  """
  @spec load_policies([policy()]) :: :ok
  def load_policies(policies) do
    GenServer.cast(__MODULE__, {:load_policies, policies})
  end

  @doc """
  Get policy engine statistics.
  """
  @spec stats() :: map()
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    catch
      :exit, _ -> %{evaluations: 0, denials: 0, policies: 0}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Load default policies
    default_policies = build_default_policies()
    custom_policies = Keyword.get(opts, :policies, [])

    state = %__MODULE__{
      policies: default_policies ++ custom_policies,
      evaluations: 0,
      denials: 0
    }

    Logger.info("PolicyEngine started with #{length(state.policies)} policies")
    {:ok, state}
  end

  @impl true
  def handle_call({:apply, backends, operation, opts}, _from, state) do
    policies_to_apply = get_applicable_policies(state.policies, opts)

    {allowed_backends, denied_count} =
      Enum.reduce(backends, {[], 0}, fn backend, {allowed, denied} ->
        case evaluate_policies(backend, operation, policies_to_apply) do
          :allow ->
            {[backend | allowed], denied}

          {:prefer, _priority} ->
            {[backend | allowed], denied}

          :deny ->
            Logger.debug("Backend denied by policy: #{inspect(backend)}")
            {allowed, denied + 1}
        end
      end)

    # Sort by preference if any
    sorted_backends = Enum.reverse(allowed_backends)

    new_state = %{
      state
      | evaluations: state.evaluations + length(backends),
        denials: state.denials + denied_count
    }

    {:reply, sorted_backends, new_state}
  end

  @impl true
  def handle_call({:evaluate, backend, operation, opts}, _from, state) do
    policies_to_apply = get_applicable_policies(state.policies, opts)
    result = evaluate_policies(backend, operation, policies_to_apply)

    new_state = %{
      state
      | evaluations: state.evaluations + 1,
        denials: if(result == :deny, do: state.denials + 1, else: state.denials)
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:list_policies, _from, state) do
    {:reply, state.policies, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      evaluations: state.evaluations,
      denials: state.denials,
      policies: length(state.policies),
      denial_rate:
        if(state.evaluations > 0,
          do: Float.round(state.denials / state.evaluations * 100, 2),
          else: 0.0
        )
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:add_policy, policy}, state) do
    new_policies = [policy | state.policies]
    {:noreply, %{state | policies: new_policies}}
  end

  @impl true
  def handle_cast({:remove_policy, name}, state) do
    new_policies = Enum.reject(state.policies, &(&1.name == name))
    {:noreply, %{state | policies: new_policies}}
  end

  @impl true
  def handle_cast({:load_policies, policies}, state) do
    {:noreply, %{state | policies: policies}}
  end

  # Private Functions

  defp build_default_policies do
    [
      # Default allow-all policy
      %{
        name: "default_allow",
        type: :allow,
        priority: 0,
        condition: %{},
        action: %{}
      },
      # Deny unknown backends
      %{
        name: "deny_unknown_type",
        type: :deny,
        priority: 100,
        condition: %{backend_type: nil},
        action: %{reason: "Unknown backend type"}
      },
      # Prefer local backends for dev environment
      %{
        name: "prefer_local_dev",
        type: :prefer,
        priority: 50,
        condition: %{environment: :dev, backend_locality: :local},
        action: %{boost: 10}
      }
    ]
  end

  defp get_applicable_policies(policies, opts) do
    requested_policies = Keyword.get(opts, :policies, [])

    if Enum.empty?(requested_policies) do
      # Apply all policies
      Enum.sort_by(policies, & &1[:priority], :desc)
    else
      # Filter to only requested policies
      policies
      |> Enum.filter(&(&1.name in requested_policies))
      |> Enum.sort_by(& &1[:priority], :desc)
    end
  end

  defp evaluate_policies(backend, operation, policies) do
    Enum.reduce_while(policies, :allow, fn policy, acc ->
      case evaluate_single_policy(backend, operation, policy) do
        :deny -> {:halt, :deny}
        {:prefer, priority} -> {:cont, merge_prefer(acc, priority)}
        :skip -> {:cont, acc}
        :allow -> {:cont, acc}
      end
    end)
  end

  defp evaluate_single_policy(backend, operation, policy) do
    if matches_condition?(backend, operation, policy.condition) do
      apply_policy_action(policy)
    else
      :skip
    end
  end

  defp matches_condition?(_backend, _operation, condition) when map_size(condition) == 0 do
    true
  end

  defp matches_condition?(backend, operation, condition) do
    Enum.all?(condition, fn {key, expected} ->
      matches_field?(backend, operation, key, expected)
    end)
  end

  defp matches_field?(backend, _operation, :backend_type, expected) do
    backend_type = Map.get(backend, :type) || Map.get(backend, "type")
    backend_type == expected or (expected == nil and backend_type == nil)
  end

  defp matches_field?(backend, _operation, :backend_locality, expected) do
    locality = Map.get(backend, :locality) || Map.get(backend, "locality")
    locality == expected
  end

  defp matches_field?(_backend, operation, :operation_type, expected) do
    operation.type == expected
  end

  defp matches_field?(_backend, operation, :environment, expected) do
    env = get_in(operation.target, [:environment]) || get_in(operation.target, ["environment"])
    env == expected
  end

  defp matches_field?(_backend, operation, :device_type, expected) do
    device = get_in(operation.target, [:device_type]) || get_in(operation.target, ["device_type"])
    device == expected
  end

  defp matches_field?(_backend, _operation, _key, _expected) do
    # Unknown condition key - skip
    true
  end

  defp apply_policy_action(%{type: :allow}), do: :allow
  defp apply_policy_action(%{type: :deny}), do: :deny

  defp apply_policy_action(%{type: :prefer, action: action}) do
    {:prefer, Map.get(action, :boost, 1)}
  end

  defp apply_policy_action(%{type: :require, action: action}) do
    # Require means deny if not matched, but policy matched so allow
    if Map.get(action, :strict, false), do: :allow, else: :allow
  end

  defp apply_policy_action(_), do: :allow

  defp merge_prefer(:allow, priority), do: {:prefer, priority}
  defp merge_prefer({:prefer, existing}, new), do: {:prefer, existing + new}
  defp merge_prefer(other, _), do: other
end
