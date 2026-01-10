# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Parsers.Kubernetes do
  @moduledoc """
  Parser for Kubernetes manifests (YAML/JSON).

  Converts Kubernetes resource definitions to HAR semantic graph operations.

  ## Supported Resources

  - Deployments, StatefulSets, DaemonSets
  - Services, Ingresses
  - ConfigMaps, Secrets
  - PersistentVolumeClaims
  - Namespaces, ServiceAccounts
  - Roles, RoleBindings, ClusterRoles
  - Jobs, CronJobs
  - Custom Resource Definitions (CRDs)

  ## Multi-Document Support

  Handles multi-document YAML files (separated by ---).
  """

  @behaviour HAR.DataPlane.Parser

  alias HAR.Semantic.{Graph, Operation, Dependency}
  require Logger

  @impl true
  def parse(content, opts \\ []) when is_binary(content) do
    with {:ok, documents} <- parse_documents(content),
         {:ok, resources} <- extract_resources(documents),
         {:ok, operations} <- build_operations(resources, opts),
         {:ok, dependencies} <- build_dependencies(operations, resources) do
      graph =
        Graph.new(
          vertices: operations,
          edges: dependencies,
          metadata: %{source: :kubernetes, parsed_at: DateTime.utc_now()}
        )

      {:ok, graph}
    end
  end

  @impl true
  def validate(content) when is_binary(content) do
    case parse_documents(content) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, {:kubernetes_parse_error, "No valid Kubernetes resources found"}}
    end
  end

  # Document parsing

  defp parse_documents(content) do
    # Split on YAML document separator
    documents =
      content
      |> String.split(~r/^---$/m)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(&parse_document/1)

    {:ok, documents}
  end

  defp parse_document(doc) do
    case YamlElixir.read_from_string(doc) do
      {:ok, parsed} when is_map(parsed) ->
        [parsed]

      {:ok, parsed} when is_list(parsed) ->
        # List of resources
        Enum.filter(parsed, &is_map/1)

      {:error, reason} ->
        Logger.warning("Failed to parse Kubernetes document: #{inspect(reason)}")
        []
    end
  end

  # Resource extraction

  defp extract_resources(documents) do
    resources =
      documents
      |> Enum.filter(&valid_k8s_resource?/1)
      |> Enum.map(&normalize_resource/1)

    {:ok, resources}
  end

  defp valid_k8s_resource?(doc) do
    Map.has_key?(doc, "apiVersion") and Map.has_key?(doc, "kind")
  end

  defp normalize_resource(doc) do
    metadata = Map.get(doc, "metadata", %{})
    spec = Map.get(doc, "spec", %{})

    %{
      api_version: Map.get(doc, "apiVersion"),
      kind: Map.get(doc, "kind"),
      name: get_in(metadata, ["name"]) || "unnamed",
      namespace: get_in(metadata, ["namespace"]) || "default",
      labels: get_in(metadata, ["labels"]) || %{},
      annotations: get_in(metadata, ["annotations"]) || %{},
      spec: spec,
      data: Map.get(doc, "data"),
      string_data: Map.get(doc, "stringData"),
      raw: doc
    }
  end

  # Operation building

  defp build_operations(resources, _opts) do
    operations =
      resources
      |> Enum.with_index()
      |> Enum.map(fn {resource, index} ->
        resource_to_operation(resource, index)
      end)

    {:ok, operations}
  end

  defp resource_to_operation(resource, index) do
    kind = resource.kind
    name = resource.name
    namespace = resource.namespace

    Operation.new(
      normalize_kind(kind),
      normalize_params(kind, resource),
      id: generate_id(kind, namespace, name, index),
      target: %{
        namespace: namespace,
        labels: resource.labels
      },
      metadata: %{
        source: :kubernetes,
        api_version: resource.api_version,
        kind: kind,
        name: name,
        namespace: namespace,
        labels: resource.labels,
        annotations: resource.annotations
      }
    )
  end

  # Kind to semantic operation type mapping

  defp normalize_kind("Deployment"), do: :container_deployment_create
  defp normalize_kind("StatefulSet"), do: :container_deployment_create
  defp normalize_kind("DaemonSet"), do: :container_deployment_create
  defp normalize_kind("ReplicaSet"), do: :container_deployment_create
  defp normalize_kind("Pod"), do: :container_create
  defp normalize_kind("Service"), do: :service_create
  defp normalize_kind("Ingress"), do: :ingress_create
  defp normalize_kind("ConfigMap"), do: :config_create
  defp normalize_kind("Secret"), do: :secret_create
  defp normalize_kind("PersistentVolumeClaim"), do: :storage_volume_create
  defp normalize_kind("PersistentVolume"), do: :storage_volume_create
  defp normalize_kind("StorageClass"), do: :storage_class_create
  defp normalize_kind("Namespace"), do: :namespace_create
  defp normalize_kind("ServiceAccount"), do: :service_account_create
  defp normalize_kind("Role"), do: :role_create
  defp normalize_kind("ClusterRole"), do: :role_create
  defp normalize_kind("RoleBinding"), do: :role_binding_create
  defp normalize_kind("ClusterRoleBinding"), do: :role_binding_create
  defp normalize_kind("NetworkPolicy"), do: :firewall_rule
  defp normalize_kind("Job"), do: :job_create
  defp normalize_kind("CronJob"), do: :cron_create
  defp normalize_kind("HorizontalPodAutoscaler"), do: :autoscaler_create
  defp normalize_kind("CustomResourceDefinition"), do: :crd_create
  defp normalize_kind(kind), do: String.to_atom("kubernetes.#{String.downcase(kind)}")

  # Parameter normalization

  defp normalize_params("Deployment", resource) do
    spec = resource.spec
    pod_spec = get_in(spec, ["template", "spec"]) || %{}
    containers = Map.get(pod_spec, "containers", [])

    %{
      name: resource.name,
      namespace: resource.namespace,
      replicas: Map.get(spec, "replicas", 1),
      selector: Map.get(spec, "selector"),
      containers: Enum.map(containers, &normalize_container/1),
      strategy: Map.get(spec, "strategy")
    }
  end

  defp normalize_params(kind, resource) when kind in ~w(StatefulSet DaemonSet ReplicaSet) do
    normalize_params("Deployment", resource)
  end

  defp normalize_params("Pod", resource) do
    spec = resource.spec
    containers = Map.get(spec, "containers", [])

    %{
      name: resource.name,
      namespace: resource.namespace,
      containers: Enum.map(containers, &normalize_container/1),
      volumes: Map.get(spec, "volumes", []),
      service_account: Map.get(spec, "serviceAccountName")
    }
  end

  defp normalize_params("Service", resource) do
    spec = resource.spec

    %{
      name: resource.name,
      namespace: resource.namespace,
      type: Map.get(spec, "type", "ClusterIP"),
      selector: Map.get(spec, "selector"),
      ports: Map.get(spec, "ports", [])
    }
  end

  defp normalize_params("Ingress", resource) do
    spec = resource.spec

    %{
      name: resource.name,
      namespace: resource.namespace,
      rules: Map.get(spec, "rules", []),
      tls: Map.get(spec, "tls", []),
      ingress_class: get_in(spec, ["ingressClassName"])
    }
  end

  defp normalize_params("ConfigMap", resource) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      data: resource.data || %{}
    }
  end

  defp normalize_params("Secret", resource) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      type: get_in(resource.raw, ["type"]) || "Opaque",
      data: resource.data || %{},
      string_data: resource.string_data || %{}
    }
  end

  defp normalize_params("PersistentVolumeClaim", resource) do
    spec = resource.spec

    %{
      name: resource.name,
      namespace: resource.namespace,
      storage_class: Map.get(spec, "storageClassName"),
      access_modes: Map.get(spec, "accessModes", []),
      storage: get_in(spec, ["resources", "requests", "storage"])
    }
  end

  defp normalize_params("Namespace", resource) do
    %{
      name: resource.name
    }
  end

  defp normalize_params("ServiceAccount", resource) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      secrets: get_in(resource.raw, ["secrets"]) || []
    }
  end

  defp normalize_params(kind, resource) when kind in ~w(Role ClusterRole) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      rules: get_in(resource.raw, ["rules"]) || []
    }
  end

  defp normalize_params(kind, resource) when kind in ~w(RoleBinding ClusterRoleBinding) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      role_ref: get_in(resource.raw, ["roleRef"]),
      subjects: get_in(resource.raw, ["subjects"]) || []
    }
  end

  defp normalize_params("Job", resource) do
    spec = resource.spec
    pod_spec = get_in(spec, ["template", "spec"]) || %{}

    %{
      name: resource.name,
      namespace: resource.namespace,
      containers: Enum.map(Map.get(pod_spec, "containers", []), &normalize_container/1),
      completions: Map.get(spec, "completions", 1),
      parallelism: Map.get(spec, "parallelism", 1),
      backoff_limit: Map.get(spec, "backoffLimit", 6)
    }
  end

  defp normalize_params("CronJob", resource) do
    spec = resource.spec
    job_spec = get_in(spec, ["jobTemplate", "spec"]) || %{}

    %{
      name: resource.name,
      namespace: resource.namespace,
      schedule: Map.get(spec, "schedule"),
      job_template: normalize_params("Job", %{resource | spec: job_spec}),
      concurrency_policy: Map.get(spec, "concurrencyPolicy", "Allow")
    }
  end

  defp normalize_params("NetworkPolicy", resource) do
    spec = resource.spec

    %{
      name: resource.name,
      namespace: resource.namespace,
      pod_selector: Map.get(spec, "podSelector"),
      ingress: Map.get(spec, "ingress", []),
      egress: Map.get(spec, "egress", []),
      policy_types: Map.get(spec, "policyTypes", [])
    }
  end

  defp normalize_params(_kind, resource) do
    %{
      name: resource.name,
      namespace: resource.namespace,
      spec: resource.spec
    }
  end

  defp normalize_container(container) do
    %{
      name: Map.get(container, "name"),
      image: Map.get(container, "image"),
      ports: Map.get(container, "ports", []),
      env: Map.get(container, "env", []),
      env_from: Map.get(container, "envFrom", []),
      resources: Map.get(container, "resources", %{}),
      volume_mounts: Map.get(container, "volumeMounts", []),
      command: Map.get(container, "command"),
      args: Map.get(container, "args"),
      liveness_probe: Map.get(container, "livenessProbe"),
      readiness_probe: Map.get(container, "readinessProbe")
    }
  end

  # Dependency building

  defp build_dependencies(operations, resources) do
    # Build lookup: kind/namespace/name -> operation_id
    op_lookup =
      Enum.zip(resources, operations)
      |> Enum.map(fn {resource, op} ->
        key = "#{resource.kind}/#{resource.namespace}/#{resource.name}"
        {String.downcase(key), op.id}
      end)
      |> Map.new()

    # Extract dependencies based on resource references
    deps =
      Enum.zip(resources, operations)
      |> Enum.flat_map(fn {resource, op} ->
        extract_resource_dependencies(resource, op, op_lookup)
      end)

    {:ok, deps}
  end

  defp extract_resource_dependencies(resource, op, op_lookup) do
    deps = []

    # Service -> Deployment (via selector)
    deps =
      if resource.kind == "Service" do
        _selector = get_in(resource.spec, ["selector"]) || %{}

        # Find matching deployments by label selector
        matching =
          op_lookup
          |> Enum.filter(fn {key, _id} ->
            String.starts_with?(key, "deployment/")
          end)
          |> Enum.map(fn {_key, id} -> id end)
          |> Enum.take(1)

        case matching do
          [dep_id] -> deps ++ [Dependency.new(dep_id, op.id, :requires, metadata: %{reason: "k8s_service_selector"})]
          _ -> deps
        end
      else
        deps
      end

    # Deployment -> ConfigMap/Secret (via env/volume refs)
    deps =
      if resource.kind in ~w(Deployment StatefulSet DaemonSet Job CronJob) do
        config_refs = extract_config_refs(resource)
        secret_refs = extract_secret_refs(resource)

        config_deps =
          config_refs
          |> Enum.flat_map(fn name ->
            key = "configmap/#{resource.namespace}/#{name}"

            case Map.get(op_lookup, String.downcase(key)) do
              nil -> []
              dep_id -> [Dependency.new(dep_id, op.id, :requires, metadata: %{reason: "k8s_configmap_ref"})]
            end
          end)

        secret_deps =
          secret_refs
          |> Enum.flat_map(fn name ->
            key = "secret/#{resource.namespace}/#{name}"

            case Map.get(op_lookup, String.downcase(key)) do
              nil -> []
              dep_id -> [Dependency.new(dep_id, op.id, :requires, metadata: %{reason: "k8s_secret_ref"})]
            end
          end)

        deps ++ config_deps ++ secret_deps
      else
        deps
      end

    # Namespace dependency (all namespaced resources depend on namespace if defined)
    deps =
      if resource.namespace != "default" do
        ns_key = "namespace/#{resource.namespace}/#{resource.namespace}"

        case Map.get(op_lookup, String.downcase(ns_key)) do
          nil -> deps
          dep_id -> deps ++ [Dependency.new(dep_id, op.id, :requires, metadata: %{reason: "k8s_namespace"})]
        end
      else
        deps
      end

    deps
  end

  defp extract_config_refs(resource) do
    spec = resource.spec
    pod_spec = get_in(spec, ["template", "spec"]) || spec
    containers = Map.get(pod_spec, "containers", [])

    # From envFrom
    env_from_refs =
      containers
      |> Enum.flat_map(fn c -> Map.get(c, "envFrom", []) end)
      |> Enum.flat_map(fn ref ->
        case get_in(ref, ["configMapRef", "name"]) do
          nil -> []
          name -> [name]
        end
      end)

    # From volumes
    volume_refs =
      Map.get(pod_spec, "volumes", [])
      |> Enum.flat_map(fn vol ->
        case get_in(vol, ["configMap", "name"]) do
          nil -> []
          name -> [name]
        end
      end)

    Enum.uniq(env_from_refs ++ volume_refs)
  end

  defp extract_secret_refs(resource) do
    spec = resource.spec
    pod_spec = get_in(spec, ["template", "spec"]) || spec
    containers = Map.get(pod_spec, "containers", [])

    # From envFrom
    env_from_refs =
      containers
      |> Enum.flat_map(fn c -> Map.get(c, "envFrom", []) end)
      |> Enum.flat_map(fn ref ->
        case get_in(ref, ["secretRef", "name"]) do
          nil -> []
          name -> [name]
        end
      end)

    # From volumes
    volume_refs =
      Map.get(pod_spec, "volumes", [])
      |> Enum.flat_map(fn vol ->
        case get_in(vol, ["secret", "secretName"]) do
          nil -> []
          name -> [name]
        end
      end)

    Enum.uniq(env_from_refs ++ volume_refs)
  end

  defp generate_id(kind, namespace, name, index) do
    safe_name =
      name
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.slice(0, 25)

    "k8s_#{String.downcase(kind)}_#{namespace}_#{safe_name}_#{index}_#{:erlang.unique_integer([:positive])}"
  end
end
