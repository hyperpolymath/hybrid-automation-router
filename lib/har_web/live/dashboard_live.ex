# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView for HAR web interface.

  Shows an overview of HAR capabilities, supported formats, and quick actions.
  """

  use HARWeb, :live_view

  @supported_formats [
    {:ansible, "Ansible", "YAML playbooks and roles", "#ef4444"},
    {:salt, "Salt", "SLS states and pillars", "#22c55e"},
    {:terraform, "Terraform", "HCL configurations", "#8b5cf6"},
    {:puppet, "Puppet", "Manifests and modules", "#f97316"},
    {:chef, "Chef", "Recipes and cookbooks", "#ec4899"},
    {:kubernetes, "Kubernetes", "YAML manifests", "#3b82f6"},
    {:docker_compose, "Docker Compose", "Compose files", "#0ea5e9"},
    {:cloudformation, "CloudFormation", "AWS templates", "#f59e0b"},
    {:pulumi, "Pulumi", "YAML configurations", "#a855f7"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Dashboard",
       formats: @supported_formats,
       stats: get_stats()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Hero Section -->
      <div class="card" style="text-align: center; padding: 3rem 1.5rem; background: linear-gradient(135deg, #1e3a8a 0%, #3730a3 100%);">
        <h1 style="font-size: 2.5rem; font-weight: bold; margin: 0 0 1rem;">
          Think BGP for Infrastructure Automation
        </h1>
        <p style="color: #bfdbfe; font-size: 1.125rem; max-width: 800px; margin: 0 auto 2rem;">
          HAR parses configurations from any IaC tool, extracts semantic operations,
          and routes/transforms them to any target format.
        </p>
        <a href="/transform" class="btn btn-primary" style="font-size: 1.125rem; padding: 0.75rem 2rem;">
          Start Transforming
        </a>
      </div>

      <!-- Stats Cards -->
      <div class="grid grid-cols-2" style="grid-template-columns: repeat(4, 1fr); margin: 2rem 0;">
        <div class="card" style="text-align: center;">
          <div style="font-size: 2.5rem; font-weight: bold; color: #3b82f6;"><%= @stats.formats %></div>
          <div style="color: #9ca3af;">Supported Formats</div>
        </div>
        <div class="card" style="text-align: center;">
          <div style="font-size: 2.5rem; font-weight: bold; color: #22c55e;"><%= @stats.operations %></div>
          <div style="color: #9ca3af;">Operation Types</div>
        </div>
        <div class="card" style="text-align: center;">
          <div style="font-size: 2.5rem; font-weight: bold; color: #f59e0b;"><%= @stats.routes %></div>
          <div style="color: #9ca3af;">Routing Rules</div>
        </div>
        <div class="card" style="text-align: center;">
          <div style="font-size: 2.5rem; font-weight: bold; color: #a855f7;"><%= @stats.transformations %></div>
          <div style="color: #9ca3af;">Possible Transforms</div>
        </div>
      </div>

      <!-- Supported Formats -->
      <h2 style="font-size: 1.5rem; font-weight: 600; margin-bottom: 1rem;">Supported Formats</h2>
      <div class="grid" style="grid-template-columns: repeat(3, 1fr); gap: 1rem;">
        <%= for {_id, name, desc, color} <- @formats do %>
          <div class="card" style="display: flex; align-items: flex-start; gap: 1rem;">
            <div style={"width: 3rem; height: 3rem; border-radius: 0.5rem; background: #{color}20; display: flex; align-items: center; justify-content: center; flex-shrink: 0;"}>
              <div style={"width: 1.5rem; height: 1.5rem; border-radius: 0.25rem; background: #{color};"}></div>
            </div>
            <div>
              <h3 style="font-weight: 600; margin: 0 0 0.25rem;"><%= name %></h3>
              <p style="color: #9ca3af; margin: 0; font-size: 0.875rem;"><%= desc %></p>
            </div>
          </div>
        <% end %>
      </div>

      <!-- How It Works -->
      <h2 style="font-size: 1.5rem; font-weight: 600; margin: 2rem 0 1rem;">How It Works</h2>
      <div class="card">
        <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 2rem;">
          <div style="flex: 1; min-width: 200px; text-align: center;">
            <div style="width: 3rem; height: 3rem; border-radius: 50%; background: #3b82f6; display: flex; align-items: center; justify-content: center; margin: 0 auto 1rem; font-weight: bold;">1</div>
            <h4 style="margin: 0 0 0.5rem;">Parse</h4>
            <p style="color: #9ca3af; font-size: 0.875rem; margin: 0;">Input your IaC configuration in any supported format</p>
          </div>
          <div style="color: #6b7280; font-size: 1.5rem;">→</div>
          <div style="flex: 1; min-width: 200px; text-align: center;">
            <div style="width: 3rem; height: 3rem; border-radius: 50%; background: #8b5cf6; display: flex; align-items: center; justify-content: center; margin: 0 auto 1rem; font-weight: bold;">2</div>
            <h4 style="margin: 0 0 0.5rem;">Semantic Graph</h4>
            <p style="color: #9ca3af; font-size: 0.875rem; margin: 0;">HAR extracts semantic operations and dependencies</p>
          </div>
          <div style="color: #6b7280; font-size: 1.5rem;">→</div>
          <div style="flex: 1; min-width: 200px; text-align: center;">
            <div style="width: 3rem; height: 3rem; border-radius: 50%; background: #22c55e; display: flex; align-items: center; justify-content: center; margin: 0 auto 1rem; font-weight: bold;">3</div>
            <h4 style="margin: 0 0 0.5rem;">Transform</h4>
            <p style="color: #9ca3af; font-size: 0.875rem; margin: 0;">Generate output in your target format</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp get_stats do
    %{
      formats: length(@supported_formats),
      operations: 50,
      routes: 100,
      transformations: length(@supported_formats) * (length(@supported_formats) - 1)
    }
  end
end
