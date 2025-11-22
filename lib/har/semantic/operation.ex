defmodule HAR.Semantic.Operation do
  @moduledoc """
  Represents a single infrastructure operation in the semantic graph.

  Operations are the fundamental unit of work in HAR - they represent
  platform-agnostic infrastructure actions like "install package" or
  "start service", independent of the source or target tool.
  """

  @type operation_type ::
          :package_install
          | :package_remove
          | :package_upgrade
          | :service_start
          | :service_stop
          | :service_restart
          | :service_enable
          | :service_disable
          | :file_write
          | :file_copy
          | :file_template
          | :file_delete
          | :file_permissions
          | :directory_create
          | :directory_delete
          | :user_create
          | :user_delete
          | :user_modify
          | :group_create
          | :group_delete
          | :group_modify
          | :network_interface
          | :network_route
          | :firewall_rule
          | :script_execute
          | :command_run
          | :compute_instance_create
          | :compute_instance_delete
          | :storage_bucket_create
          | :storage_bucket_delete
          | atom()

  @type target :: %{
          optional(:os) => String.t(),
          optional(:arch) => String.t(),
          optional(:ipv6) => String.t(),
          optional(:ipv6_prefix) => String.t(),
          optional(:mac) => String.t(),
          optional(:environment) => :dev | :staging | :prod,
          optional(:device_type) => atom(),
          optional(:region) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: operation_type(),
          params: map(),
          target: target(),
          metadata: map()
        }

  defstruct [
    :id,
    :type,
    :params,
    :target,
    :metadata
  ]

  @doc """
  Create a new operation with a generated UUID.

  ## Examples

      iex> op = Operation.new(:package_install, %{package: "nginx"})
      iex> op.type
      :package_install
  """
  def new(type, params, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      type: type,
      params: params,
      target: Keyword.get(opts, :target, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Validate operation parameters for a given type.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{type: :package_install, params: params}) do
    if Map.has_key?(params, :package) or Map.has_key?(params, :name) do
      :ok
    else
      {:error, {:missing_param, :package}}
    end
  end

  def validate(%__MODULE__{type: :service_start, params: params}) do
    if Map.has_key?(params, :service) or Map.has_key?(params, :name) do
      :ok
    else
      {:error, {:missing_param, :service}}
    end
  end

  def validate(%__MODULE__{type: :file_write, params: params}) do
    cond do
      not Map.has_key?(params, :path) ->
        {:error, {:missing_param, :path}}

      not (Map.has_key?(params, :content) or Map.has_key?(params, :source)) ->
        {:error, {:missing_param, :content_or_source}}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{}), do: :ok

  @doc """
  Convert operation to a string representation.
  """
  def to_string(%__MODULE__{type: type, params: params}) do
    "#{type}(#{inspect(params, limit: 3)})"
  end

  defp generate_id do
    UUID.uuid4()
  end

  defmodule UUID do
    @moduledoc false

    def uuid4 do
      <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

      <<u0::48, 4::4, u1::12, 2::2, u2::62>>
      |> uuid_to_string()
    end

    defp uuid_to_string(<<
           a1::4,
           a2::4,
           a3::4,
           a4::4,
           a5::4,
           a6::4,
           a7::4,
           a8::4,
           b1::4,
           b2::4,
           b3::4,
           b4::4,
           c1::4,
           c2::4,
           c3::4,
           c4::4,
           d1::4,
           d2::4,
           d3::4,
           d4::4,
           e1::4,
           e2::4,
           e3::4,
           e4::4,
           e5::4,
           e6::4,
           e7::4,
           e8::4,
           e9::4,
           e10::4,
           e11::4,
           e12::4
         >>) do
      <<e(a1), e(a2), e(a3), e(a4), e(a5), e(a6), e(a7), e(a8), ?-, e(b1), e(b2), e(b3), e(b4),
        ?-, e(c1), e(c2), e(c3), e(c4), ?-, e(d1), e(d2), e(d3), e(d4), ?-, e(e1), e(e2), e(e3),
        e(e4), e(e5), e(e6), e(e7), e(e8), e(e9), e(e10), e(e11), e(e12)>>
    end

    defp e(n) when n < 10, do: ?0 + n
    defp e(n), do: ?a + n - 10
  end
end
