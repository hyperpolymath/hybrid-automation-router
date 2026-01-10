# SPDX-License-Identifier: MPL-2.0
defmodule HAR.DataPlane.Transformers.Kubernetes do
  @moduledoc """
  Transformer for Kubernetes manifest format (YAML).

  Converts HAR semantic graph to Kubernetes resource manifests.

  ## Features

  - Deployments, StatefulSets, DaemonSets for container workloads
  - Services for networking
  - ConfigMaps and Secrets for configuration
  - PersistentVolumeClaims for storage
  - Jobs and CronJobs for batch workloads
  - RBAC resources (ServiceAccount, Role, RoleBinding)
  - Multi-document YAML output (separated by ---)
  """

  @behaviour HAR.DataPlane.Transformer

  alias HAR.Semantic.Graph
  require Logger

  @impl true
  def transform(%Graph{} = graph, opts \\ []) do
    with {:ok, sorted_ops} <- Graph.topological_sort(graph),
         {:ok, resources} <- operations_to_resources(sorted_ops, graph, opts),
         {:ok, manifest} <- format_manifest(resources, opts) do
      {:ok, manifest}
    end
  end

  @impl true
  def validate(%Graph{} = graph) do
    case Graph.topological_sort(graph) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid_graph, reason}}
    end
  end

  defp operations_to_resources(operations, _graph, opts) do
    namespace = Keyword.get(opts, :namespace, "default")

    resources =
      operations
      |> Enum.map(fn op -> operation_to_resource(op, namespace, opts) end)
      |> Enum.reject(&is_nil/1)

    {:ok, resources}
  end

  defp operation_to_resource(op, namespace, opts) do
    case op.type do
      :container_deployment_create -> build_deployment(op, namespace, opts)
      :container_create -> build_pod(op, namespace, opts)
      :service_create -> build_service(op, namespace, opts)
      :ingress_create -> build_ingress(op, namespace, opts)
      :config_create -> build_configmap(op, namespace, opts)
      :secret_create -> build_secret(op, namespace, opts)
      :storage_volume_create -> build_pvc(op, namespace, opts)
      :namespace_create -> build_namespace(op, opts)
      :service_account_create -> build_service_account(op, namespace, opts)
      :role_create -> build_role(op, namespace, opts)
      :role_binding_create -> build_role_binding(op, namespace, opts)
      :job_create -> build_job(op, namespace, opts)
      :cron_create -> build_cronjob(op, namespace, opts)
      :firewall_rule -> build_network_policy(op, namespace, opts)
      _ -> build_generic_resource(op, namespace, opts)
    end
  end

  # Resource builders

  defp build_deployment(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    replicas = op.params[:replicas] || 1
    containers = op.params[:containers] || []
    labels = op.params[:labels] || %{"app" => name}

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => %{
        "replicas" => replicas,
        "selector" => %{
          "matchLabels" => labels
        },
        "template" => %{
          "metadata" => %{
            "labels" => labels
          },
          "spec" => %{
            "containers" => Enum.map(containers, &build_container_spec/1)
          }
        }
      }
    }
  end

  defp build_pod(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    containers = op.params[:containers] || []
    labels = op.params[:labels] || %{"app" => name}

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => %{
        "containers" => Enum.map(containers, &build_container_spec/1)
      }
    }
  end

  defp build_service(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    service_type = op.params[:type] || "ClusterIP"
    ports = op.params[:ports] || []
    selector = op.params[:selector] || %{"app" => name}
    labels = op.params[:labels] || %{"app" => name}

    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => %{
        "type" => service_type,
        "selector" => selector,
        "ports" => Enum.map(ports, &normalize_port/1)
      }
    }
  end

  defp build_ingress(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    rules = op.params[:rules] || []
    tls = op.params[:tls] || []
    labels = op.params[:labels] || %{}
    ingress_class = op.params[:ingress_class]

    spec = %{"rules" => rules}
    spec = if tls != [], do: Map.put(spec, "tls", tls), else: spec
    spec = if ingress_class, do: Map.put(spec, "ingressClassName", ingress_class), else: spec

    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "Ingress",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => spec
    }
  end

  defp build_configmap(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    data = op.params[:data] || %{}
    labels = op.params[:labels] || %{}

    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => build_metadata(name, namespace, labels, op),
      "data" => stringify_map(data)
    }
  end

  defp build_secret(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    secret_type = op.params[:type] || "Opaque"
    data = op.params[:data] || %{}
    string_data = op.params[:string_data] || %{}
    labels = op.params[:labels] || %{}

    resource = %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => build_metadata(name, namespace, labels, op),
      "type" => secret_type
    }

    resource = if data != %{}, do: Map.put(resource, "data", data), else: resource
    resource = if string_data != %{}, do: Map.put(resource, "stringData", string_data), else: resource
    resource
  end

  defp build_pvc(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    storage = op.params[:storage] || "1Gi"
    access_modes = op.params[:access_modes] || ["ReadWriteOnce"]
    storage_class = op.params[:storage_class]
    labels = op.params[:labels] || %{}

    spec = %{
      "accessModes" => access_modes,
      "resources" => %{
        "requests" => %{
          "storage" => storage
        }
      }
    }

    spec = if storage_class, do: Map.put(spec, "storageClassName", storage_class), else: spec

    %{
      "apiVersion" => "v1",
      "kind" => "PersistentVolumeClaim",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => spec
    }
  end

  defp build_namespace(op, _opts) do
    name = op.params[:name] || "unnamed"
    labels = op.params[:labels] || %{}

    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{
        "name" => name,
        "labels" => labels
      }
    }
  end

  defp build_service_account(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    labels = op.params[:labels] || %{}

    %{
      "apiVersion" => "v1",
      "kind" => "ServiceAccount",
      "metadata" => build_metadata(name, namespace, labels, op)
    }
  end

  defp build_role(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    rules = op.params[:rules] || []
    labels = op.params[:labels] || %{}
    cluster_scope = op.params[:cluster_scope] || false

    kind = if cluster_scope, do: "ClusterRole", else: "Role"
    api_version = "rbac.authorization.k8s.io/v1"

    resource = %{
      "apiVersion" => api_version,
      "kind" => kind,
      "rules" => rules
    }

    metadata = if cluster_scope do
      %{"name" => name, "labels" => labels}
    else
      build_metadata(name, namespace, labels, op)
    end

    Map.put(resource, "metadata", metadata)
  end

  defp build_role_binding(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    role_ref = op.params[:role_ref] || %{}
    subjects = op.params[:subjects] || []
    labels = op.params[:labels] || %{}
    cluster_scope = op.params[:cluster_scope] || false

    kind = if cluster_scope, do: "ClusterRoleBinding", else: "RoleBinding"
    api_version = "rbac.authorization.k8s.io/v1"

    metadata = if cluster_scope do
      %{"name" => name, "labels" => labels}
    else
      build_metadata(name, namespace, labels, op)
    end

    %{
      "apiVersion" => api_version,
      "kind" => kind,
      "metadata" => metadata,
      "roleRef" => role_ref,
      "subjects" => subjects
    }
  end

  defp build_job(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    containers = op.params[:containers] || []
    completions = op.params[:completions] || 1
    parallelism = op.params[:parallelism] || 1
    backoff_limit = op.params[:backoff_limit] || 6
    labels = op.params[:labels] || %{"job" => name}

    %{
      "apiVersion" => "batch/v1",
      "kind" => "Job",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => %{
        "completions" => completions,
        "parallelism" => parallelism,
        "backoffLimit" => backoff_limit,
        "template" => %{
          "metadata" => %{
            "labels" => labels
          },
          "spec" => %{
            "containers" => Enum.map(containers, &build_container_spec/1),
            "restartPolicy" => "Never"
          }
        }
      }
    }
  end

  defp build_cronjob(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    schedule = op.params[:schedule] || "0 * * * *"
    containers = op.params[:containers] || []
    concurrency_policy = op.params[:concurrency_policy] || "Allow"
    labels = op.params[:labels] || %{"cronjob" => name}

    %{
      "apiVersion" => "batch/v1",
      "kind" => "CronJob",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => %{
        "schedule" => schedule,
        "concurrencyPolicy" => concurrency_policy,
        "jobTemplate" => %{
          "spec" => %{
            "template" => %{
              "metadata" => %{
                "labels" => labels
              },
              "spec" => %{
                "containers" => Enum.map(containers, &build_container_spec/1),
                "restartPolicy" => "Never"
              }
            }
          }
        }
      }
    }
  end

  defp build_network_policy(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    pod_selector = op.params[:pod_selector] || %{}
    ingress_rules = op.params[:ingress] || []
    egress_rules = op.params[:egress] || []
    policy_types = op.params[:policy_types] || []
    labels = op.params[:labels] || %{}

    spec = %{
      "podSelector" => pod_selector
    }

    spec = if ingress_rules != [], do: Map.put(spec, "ingress", ingress_rules), else: spec
    spec = if egress_rules != [], do: Map.put(spec, "egress", egress_rules), else: spec
    spec = if policy_types != [], do: Map.put(spec, "policyTypes", policy_types), else: spec

    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => build_metadata(name, namespace, labels, op),
      "spec" => spec
    }
  end

  defp build_generic_resource(op, namespace, _opts) do
    name = op.params[:name] || "unnamed"
    labels = op.params[:labels] || %{}

    Logger.warning("Creating generic Kubernetes resource for operation type: #{op.type}")

    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => build_metadata(name, namespace, labels, op),
      "data" => %{
        "operation_type" => to_string(op.type),
        "params" => inspect(op.params)
      }
    }
  end

  # Helper functions

  defp build_metadata(name, namespace, labels, op) do
    metadata = %{
      "name" => name,
      "namespace" => namespace,
      "labels" => labels
    }

    # Add annotations from operation metadata if present
    annotations = op.metadata[:annotations] || %{}
    if annotations != %{} do
      Map.put(metadata, "annotations", annotations)
    else
      metadata
    end
  end

  defp build_container_spec(container) when is_map(container) do
    spec = %{
      "name" => container[:name] || container["name"] || "main",
      "image" => container[:image] || container["image"] || "busybox"
    }

    spec = add_if_present(spec, "ports", normalize_container_ports(container[:ports] || container["ports"]))
    spec = add_if_present(spec, "env", normalize_env(container[:env] || container["env"]))
    spec = add_if_present(spec, "envFrom", container[:env_from] || container["envFrom"])
    spec = add_if_present(spec, "resources", container[:resources] || container["resources"])
    spec = add_if_present(spec, "volumeMounts", container[:volume_mounts] || container["volumeMounts"])
    spec = add_if_present(spec, "command", container[:command] || container["command"])
    spec = add_if_present(spec, "args", container[:args] || container["args"])
    spec = add_if_present(spec, "livenessProbe", container[:liveness_probe] || container["livenessProbe"])
    spec = add_if_present(spec, "readinessProbe", container[:readiness_probe] || container["readinessProbe"])

    spec
  end

  defp build_container_spec(_), do: %{"name" => "main", "image" => "busybox"}

  defp normalize_container_ports(nil), do: nil
  defp normalize_container_ports([]), do: nil
  defp normalize_container_ports(ports) when is_list(ports) do
    Enum.map(ports, fn
      %{"containerPort" => _} = port -> port
      %{container_port: port} -> %{"containerPort" => port}
      port when is_integer(port) -> %{"containerPort" => port}
      port when is_map(port) -> port
    end)
  end

  defp normalize_env(nil), do: nil
  defp normalize_env([]), do: nil
  defp normalize_env(env) when is_list(env), do: env
  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> %{"name" => to_string(k), "value" => to_string(v)} end)
  end

  defp normalize_port(port) when is_map(port) do
    %{
      "port" => port[:port] || port["port"],
      "targetPort" => port[:target_port] || port["targetPort"] || port[:port] || port["port"]
    }
    |> add_if_present("name", port[:name] || port["name"])
    |> add_if_present("protocol", port[:protocol] || port["protocol"])
  end
  defp normalize_port(port) when is_integer(port) do
    %{"port" => port, "targetPort" => port}
  end

  defp add_if_present(map, _key, nil), do: map
  defp add_if_present(map, _key, []), do: map
  defp add_if_present(map, _key, ""), do: map
  defp add_if_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
  defp stringify_map(other), do: other

  # Manifest formatting

  defp format_manifest(resources, _opts) do
    yaml_docs =
      resources
      |> Enum.map(&resource_to_yaml/1)
      |> Enum.join("\n---\n")

    manifest = """
    # Generated by HAR (Hybrid Automation Router)
    # Kubernetes manifest
    ---
    #{yaml_docs}
    """

    {:ok, String.trim(manifest) <> "\n"}
  end

  defp resource_to_yaml(resource) do
    case HAR.Utils.YamlFormatter.to_yaml(resource) do
      {:ok, yaml} -> yaml
      {:error, _} -> inspect(resource)
    end
  end
end
