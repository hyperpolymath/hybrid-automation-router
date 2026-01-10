# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.TransformLive do
  @moduledoc """
  Transform LiveView for HAR web interface.

  Provides an interactive interface for transforming IaC configurations
  between different formats.
  """

  use HARWeb, :live_view

  alias HAR.DataPlane.{Parser, Transformer}
  alias HAR.Semantic.Graph

  @formats [
    {"ansible", "Ansible"},
    {"salt", "Salt"},
    {"terraform", "Terraform"},
    {"puppet", "Puppet"},
    {"chef", "Chef"},
    {"kubernetes", "Kubernetes"},
    {"docker_compose", "Docker Compose"},
    {"cloudformation", "CloudFormation"},
    {"pulumi", "Pulumi"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Transform",
       formats: @formats,
       source_format: "ansible",
       target_format: "salt",
       source_content: sample_ansible(),
       output_content: "",
       graph_info: nil,
       error: nil,
       transforming: false
     )}
  end

  @impl true
  def handle_event("update_source", %{"source" => content}, socket) do
    {:noreply, assign(socket, source_content: content, error: nil)}
  end

  @impl true
  def handle_event("update_source_format", %{"format" => format}, socket) do
    sample = get_sample(format)
    {:noreply, assign(socket, source_format: format, source_content: sample, error: nil, output_content: "")}
  end

  @impl true
  def handle_event("update_target_format", %{"format" => format}, socket) do
    {:noreply, assign(socket, target_format: format, error: nil)}
  end

  @impl true
  def handle_event("transform", _params, socket) do
    socket = assign(socket, transforming: true, error: nil)

    source_format = String.to_existing_atom(socket.assigns.source_format)
    target_format = String.to_existing_atom(socket.assigns.target_format)
    content = socket.assigns.source_content

    result =
      with {:ok, graph} <- Parser.parse(source_format, content),
           {:ok, output} <- Transformer.transform(graph, to: target_format) do
        {:ok, output, graph}
      end

    socket =
      case result do
        {:ok, output, graph} ->
          assign(socket,
            output_content: output,
            graph_info: summarize_graph(graph),
            error: nil,
            transforming: false
          )

        {:error, reason} ->
          assign(socket,
            error: format_error(reason),
            transforming: false
          )
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.875rem; font-weight: bold; margin-bottom: 1.5rem;">Transform Configuration</h1>

      <!-- Format Selection -->
      <div class="card">
        <div class="grid grid-cols-2" style="gap: 2rem;">
          <div>
            <label for="source-format">Source Format</label>
            <select
              id="source-format"
              phx-change="update_source_format"
              name="format"
              style="width: 100%;"
            >
              <%= for {value, label} <- @formats do %>
                <option value={value} selected={@source_format == value}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div>
            <label for="target-format">Target Format</label>
            <select
              id="target-format"
              phx-change="update_target_format"
              name="format"
              style="width: 100%;"
            >
              <%= for {value, label} <- @formats do %>
                <option value={value} selected={@target_format == value}><%= label %></option>
              <% end %>
            </select>
          </div>
        </div>
      </div>

      <!-- Error Display -->
      <%= if @error do %>
        <div style="background: #5f1e1e; border: 1px solid #ef4444; border-radius: 0.5rem; padding: 1rem; margin-bottom: 1rem;">
          <strong style="color: #f87171;">Error:</strong>
          <span style="color: #fecaca;"><%= @error %></span>
        </div>
      <% end %>

      <!-- Input/Output Panels -->
      <div class="grid grid-cols-2" style="gap: 1rem; margin-top: 1rem;">
        <!-- Source Input -->
        <div class="card">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
            <h3 style="margin: 0; font-weight: 600;">Source Configuration</h3>
            <span style="font-size: 0.75rem; color: #6b7280; background: #374151; padding: 0.25rem 0.5rem; border-radius: 0.25rem;">
              <%= get_format_label(@source_format, @formats) %>
            </span>
          </div>
          <textarea
            phx-change="update_source"
            name="source"
            rows="20"
            style="font-family: monospace; font-size: 0.875rem; resize: vertical;"
            placeholder="Paste your configuration here..."
          ><%= @source_content %></textarea>
        </div>

        <!-- Output Panel -->
        <div class="card">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
            <h3 style="margin: 0; font-weight: 600;">Output</h3>
            <span style="font-size: 0.75rem; color: #6b7280; background: #374151; padding: 0.25rem 0.5rem; border-radius: 0.25rem;">
              <%= get_format_label(@target_format, @formats) %>
            </span>
          </div>
          <textarea
            readonly
            rows="20"
            style="font-family: monospace; font-size: 0.875rem; resize: vertical; background: #0f172a;"
            placeholder="Transformed output will appear here..."
          ><%= @output_content %></textarea>
        </div>
      </div>

      <!-- Transform Button -->
      <div style="margin-top: 1rem; text-align: center;">
        <button
          phx-click="transform"
          class="btn btn-primary"
          disabled={@transforming}
          style="padding: 0.75rem 3rem; font-size: 1.125rem;"
        >
          <%= if @transforming do %>
            <span>Transforming...</span>
          <% else %>
            Transform →
          <% end %>
        </button>
      </div>

      <!-- Graph Info -->
      <%= if @graph_info do %>
        <div class="card" style="margin-top: 1.5rem;">
          <h3 style="margin: 0 0 1rem; font-weight: 600;">Semantic Graph Summary</h3>
          <div class="grid" style="grid-template-columns: repeat(4, 1fr); gap: 1rem;">
            <div style="text-align: center; padding: 1rem; background: #374151; border-radius: 0.5rem;">
              <div style="font-size: 1.5rem; font-weight: bold; color: #3b82f6;"><%= @graph_info.operations %></div>
              <div style="font-size: 0.875rem; color: #9ca3af;">Operations</div>
            </div>
            <div style="text-align: center; padding: 1rem; background: #374151; border-radius: 0.5rem;">
              <div style="font-size: 1.5rem; font-weight: bold; color: #22c55e;"><%= @graph_info.dependencies %></div>
              <div style="font-size: 0.875rem; color: #9ca3af;">Dependencies</div>
            </div>
            <div style="text-align: center; padding: 1rem; background: #374151; border-radius: 0.5rem;">
              <div style="font-size: 1.5rem; font-weight: bold; color: #f59e0b;"><%= @graph_info.operation_types %></div>
              <div style="font-size: 0.875rem; color: #9ca3af;">Operation Types</div>
            </div>
            <div style="text-align: center; padding: 1rem; background: #374151; border-radius: 0.5rem;">
              <div style="font-size: 1.5rem; font-weight: bold; color: #a855f7;"><%= @graph_info.source_format %></div>
              <div style="font-size: 0.875rem; color: #9ca3af;">Source Format</div>
            </div>
          </div>

          <%= if @graph_info.types != [] do %>
            <div style="margin-top: 1rem;">
              <h4 style="font-size: 0.875rem; color: #9ca3af; margin-bottom: 0.5rem;">Operation Types:</h4>
              <div style="display: flex; flex-wrap: wrap; gap: 0.5rem;">
                <%= for type <- @graph_info.types do %>
                  <span style="background: #1e3a8a; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.75rem;">
                    <%= type %>
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp get_format_label(value, formats) do
    case Enum.find(formats, fn {v, _} -> v == value end) do
      {_, label} -> label
      nil -> value
    end
  end

  defp summarize_graph(%Graph{} = graph) do
    types = graph.vertices |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

    %{
      operations: length(graph.vertices),
      dependencies: length(graph.edges),
      operation_types: length(types),
      types: types,
      source_format: graph.metadata[:source_format] || "unknown"
    }
  end

  defp format_error({:yaml_parse_error, details}) do
    "YAML parse error: #{inspect(details)}"
  end

  defp format_error({:json_parse_error, details}) do
    "JSON parse error: #{inspect(details)}"
  end

  defp format_error({:unsupported_format, format}) do
    "Unsupported source format: #{format}"
  end

  defp format_error({:unsupported_target, target}) do
    "Unsupported target format: #{target}"
  end

  defp format_error({:invalid_graph, reason}) do
    "Invalid graph: #{inspect(reason)}"
  end

  defp format_error(reason) do
    "Error: #{inspect(reason)}"
  end

  defp get_sample("ansible"), do: sample_ansible()
  defp get_sample("salt"), do: sample_salt()
  defp get_sample("terraform"), do: sample_terraform()
  defp get_sample("kubernetes"), do: sample_kubernetes()
  defp get_sample("docker_compose"), do: sample_docker_compose()
  defp get_sample(_), do: "# Paste your configuration here"

  defp sample_ansible do
    """
    ---
    - name: Configure web server
      hosts: webservers
      become: true
      tasks:
        - name: Install nginx
          apt:
            name: nginx
            state: present

        - name: Start nginx service
          service:
            name: nginx
            state: started
            enabled: true

        - name: Create web user
          user:
            name: webadmin
            groups: www-data
            shell: /bin/bash
    """
  end

  defp sample_salt do
    """
    nginx:
      pkg.installed:
        - name: nginx

    nginx_service:
      service.running:
        - name: nginx
        - enable: True
        - require:
          - pkg: nginx

    webadmin:
      user.present:
        - groups:
          - www-data
        - shell: /bin/bash
    """
  end

  defp sample_terraform do
    """
    resource "aws_instance" "web" {
      ami           = "ami-12345678"
      instance_type = "t2.micro"

      tags = {
        Name = "WebServer"
      }
    }

    resource "aws_security_group" "web_sg" {
      name        = "web-sg"
      description = "Allow HTTP traffic"

      ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
    """
  end

  defp sample_kubernetes do
    """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: nginx
      labels:
        app: nginx
    spec:
      replicas: 3
      selector:
        matchLabels:
          app: nginx
      template:
        metadata:
          labels:
            app: nginx
        spec:
          containers:
          - name: nginx
            image: nginx:1.21
            ports:
            - containerPort: 80
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: nginx-service
    spec:
      selector:
        app: nginx
      ports:
      - port: 80
        targetPort: 80
      type: LoadBalancer
    """
  end

  defp sample_docker_compose do
    """
    services:
      web:
        image: nginx:latest
        ports:
          - "80:80"
        volumes:
          - ./html:/usr/share/nginx/html
        depends_on:
          - db

      db:
        image: postgres:15
        environment:
          POSTGRES_PASSWORD: secret
        volumes:
          - db_data:/var/lib/postgresql/data

    volumes:
      db_data:
    """
  end
end
