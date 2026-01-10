# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.Layouts do
  @moduledoc """
  Layout components for HAR web interface.

  This module defines the root and app layouts used by all pages.
  """

  use HARWeb, :html

  import HARWeb.CoreComponents

  embed_templates "layouts/*"
end
