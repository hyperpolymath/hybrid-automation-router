# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.GraphLive do
  @moduledoc """
  Graph visualization LiveView for HAR web interface.

  Displays semantic graphs in an interactive visualization.
  """

  use HARWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Graph View",
       graph_id: id,
       graph: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.875rem; font-weight: bold; margin-bottom: 1.5rem;">Semantic Graph</h1>

      <div class="card" style="min-height: 500px; display: flex; align-items: center; justify-content: center;">
        <div style="text-align: center; color: #6b7280;">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" style="width: 4rem; height: 4rem; margin: 0 auto 1rem;">
            <path stroke-linecap="round" stroke-linejoin="round" d="M7.5 14.25v2.25m3-4.5v4.5m3-6.75v6.75m3-9v9M6 20.25h12A2.25 2.25 0 0020.25 18V6A2.25 2.25 0 0018 3.75H6A2.25 2.25 0 003.75 6v12A2.25 2.25 0 006 20.25z" />
          </svg>
          <p>Graph visualization for ID: <%= @graph_id %></p>
          <p style="font-size: 0.875rem;">Interactive graph visualization coming in v1.1</p>
        </div>
      </div>

      <div style="margin-top: 1rem; text-align: center;">
        <a href="/transform" class="btn btn-primary">← Back to Transform</a>
      </div>
    </div>
    """
  end
end
