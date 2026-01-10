# SPDX-License-Identifier: MPL-2.0
defmodule HAR.Utils.YamlFormatter do
  @moduledoc """
  Simple YAML formatter for outputting Elixir data structures as YAML.

  Note: yaml_elixir only provides YAML reading, not writing. This module
  provides basic YAML serialization for infrastructure automation configs.
  For complex cases, consider JSON output (JSON is valid YAML).
  """

  @doc """
  Convert an Elixir data structure to a YAML string.

  ## Examples

      iex> HAR.Utils.YamlFormatter.to_yaml(%{"name" => "nginx"})
      {:ok, "name: nginx\\n"}

      iex> HAR.Utils.YamlFormatter.to_yaml([%{"hosts" => "all"}])
      {:ok, "- hosts: all\\n"}
  """
  @spec to_yaml(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_yaml(data, opts \\ []) do
    indent = Keyword.get(opts, :indent, 2)

    try do
      yaml = format_value(data, 0, indent)
      {:ok, yaml}
    rescue
      e -> {:error, {:yaml_format_error, Exception.message(e)}}
    end
  end

  @doc """
  Convert to YAML, raising on error.
  """
  @spec to_yaml!(term(), keyword()) :: String.t()
  def to_yaml!(data, opts \\ []) do
    case to_yaml(data, opts) do
      {:ok, yaml} -> yaml
      {:error, reason} -> raise "YAML formatting error: #{inspect(reason)}"
    end
  end

  # Format a value at a given indentation level
  defp format_value(value, level, indent) when is_map(value) do
    if map_size(value) == 0 do
      "{}\n"
    else
      value
      |> Enum.map(fn {k, v} -> format_map_entry(k, v, level, indent) end)
      |> Enum.join("")
    end
  end

  defp format_value(value, level, indent) when is_list(value) do
    if value == [] do
      "[]\n"
    else
      value
      |> Enum.map(fn item -> format_list_item(item, level, indent) end)
      |> Enum.join("")
    end
  end

  defp format_value(value, _level, _indent) when is_binary(value) do
    if needs_quoting?(value) do
      "#{inspect(value)}\n"
    else
      "#{value}\n"
    end
  end

  defp format_value(value, _level, _indent) when is_atom(value) do
    "#{value}\n"
  end

  defp format_value(value, _level, _indent) when is_number(value) do
    "#{value}\n"
  end

  defp format_value(value, _level, _indent) when is_boolean(value) do
    "#{value}\n"
  end

  defp format_value(nil, _level, _indent), do: "null\n"

  # Format a map entry (key: value)
  defp format_map_entry(key, value, level, indent) when is_map(value) do
    padding = String.duplicate(" ", level * indent)

    if map_size(value) == 0 do
      "#{padding}#{key}: {}\n"
    else
      nested = format_value(value, level + 1, indent)
      "#{padding}#{key}:\n#{nested}"
    end
  end

  defp format_map_entry(key, value, level, indent) when is_list(value) do
    padding = String.duplicate(" ", level * indent)

    if value == [] do
      "#{padding}#{key}: []\n"
    else
      nested = format_value(value, level + 1, indent)
      "#{padding}#{key}:\n#{nested}"
    end
  end

  defp format_map_entry(key, value, level, indent) do
    padding = String.duplicate(" ", level * indent)
    formatted_value = format_inline_value(value)
    "#{padding}#{key}: #{formatted_value}\n"
  end

  # Format a list item (- value)
  defp format_list_item(value, level, indent) when is_map(value) do
    padding = String.duplicate(" ", level * indent)

    if map_size(value) == 0 do
      "#{padding}- {}\n"
    else
      # First key on same line as dash, rest indented
      [{first_key, first_val} | rest] = Map.to_list(value)

      first_line =
        if is_map(first_val) or is_list(first_val) do
          nested = format_value(first_val, level + 2, indent)
          "#{padding}- #{first_key}:\n#{nested}"
        else
          "#{padding}- #{first_key}: #{format_inline_value(first_val)}\n"
        end

      rest_lines =
        rest
        |> Enum.map(fn {k, v} -> format_map_entry(k, v, level + 1, indent) end)
        |> Enum.join("")

      first_line <> rest_lines
    end
  end

  defp format_list_item(value, level, indent) when is_list(value) do
    padding = String.duplicate(" ", level * indent)
    nested = format_value(value, level + 1, indent)
    "#{padding}-\n#{nested}"
  end

  defp format_list_item(value, level, indent) do
    padding = String.duplicate(" ", level * indent)
    "#{padding}- #{format_inline_value(value)}\n"
  end

  # Format a value for inline display (no newline)
  defp format_inline_value(value) when is_binary(value) do
    if needs_quoting?(value), do: inspect(value), else: value
  end

  defp format_inline_value(value) when is_atom(value), do: "#{value}"
  defp format_inline_value(value) when is_number(value), do: "#{value}"
  defp format_inline_value(true), do: "true"
  defp format_inline_value(false), do: "false"
  defp format_inline_value(nil), do: "null"
  defp format_inline_value(value), do: inspect(value)

  # Check if a string needs quoting
  defp needs_quoting?(str) when is_binary(str) do
    cond do
      # Contains special YAML characters
      String.contains?(str, [": ", "#", "\n", "'", "\"", "[", "]", "{", "}", "&", "*", "!", "|", ">", "%", "@", "`"]) -> true
      # Starts with special characters
      String.match?(str, ~r/^[-:?]/) -> true
      # Could be parsed as boolean/null
      str in ["true", "false", "yes", "no", "on", "off", "null", "~"] -> true
      # Could be parsed as number
      String.match?(str, ~r/^-?[0-9]/) -> true
      # Empty string
      str == "" -> true
      true -> false
    end
  end
end
