defmodule PortalWeb.ApiDocsHTML do
  @moduledoc "The `/api/docs` page."

  use PortalWeb, :html

  embed_templates "api_docs_html/*"

  @doc """
  Text from the spec, with its `backtick` spans set as code. HEEx escapes
  every segment, so a description can never inject markup.
  """
  attr :text, :string, default: nil

  def spec_text(assigns) do
    assigns = assign(assigns, :segments, segments(assigns.text))

    ~H"""
    <%= for {kind, text} <- @segments do %>
      <%= if kind == :code do %>
        <code class="rounded bg-base-200 px-1 py-0.5 font-mono text-[0.85em]">{text}</code>
      <% else %>
        {text}
      <% end %>
    <% end %>
    """
  end

  @doc "Paragraphs of a multi-paragraph description."
  def paragraphs(nil), do: []

  def paragraphs(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp segments(nil), do: []

  defp segments(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.reject(fn {segment, _index} -> segment == "" end)
    |> Enum.map(fn {segment, index} ->
      {if(rem(index, 2) == 1, do: :code, else: :text), segment}
    end)
  end

  @doc "A schema flattened into rows (`PortalWeb.ApiDocs.fields/2`) as a table."
  attr :id, :string, required: true
  attr :fields, :list, required: true

  def field_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-xl border border-base-300">
      <table id={@id} class="w-full text-left text-sm">
        <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
          <tr>
            <th class="px-4 py-2">Field</th>
            <th class="px-4 py-2">Type</th>
            <th class="px-4 py-2">Description</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-base-200">
          <tr :for={field <- @fields} class="align-top hover:bg-base-200/40">
            <td class={[
              "whitespace-nowrap px-4 py-2 font-mono text-base-content",
              indent(field.depth)
            ]}>
              <span :if={field.depth > 0} class="text-base-content/30">└ </span>{field.name}
              <span
                :if={field.required}
                class="ml-1 text-xs font-sans font-semibold text-primary"
                title="Always present"
              >
                required
              </span>
            </td>
            <td class="px-4 py-2 font-mono text-xs text-base-content/70">{field.type}</td>
            <td class="px-4 py-2 text-base-content/70"><.spec_text text={field.description} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Literal class names, so Tailwind's source scan finds every one.
  defp indent(0), do: "pl-4"
  defp indent(1), do: "pl-8"
  defp indent(2), do: "pl-12"
  defp indent(3), do: "pl-16"
  defp indent(4), do: "pl-20"
  defp indent(_depth), do: "pl-24"

  @doc "Badge colours per HTTP status class."
  def status_class("2" <> _),
    do:
      "bg-emerald-50 text-emerald-700 ring-emerald-100 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-500/20"

  def status_class("4" <> _),
    do:
      "bg-orange-50 text-orange-700 ring-orange-100 dark:bg-orange-500/10 dark:text-orange-300 dark:ring-orange-500/20"

  def status_class(_status),
    do:
      "bg-red-50 text-red-700 ring-red-100 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-500/20"
end
