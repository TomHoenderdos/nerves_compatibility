defmodule Site.Nav do
  @moduledoc """
  Renders the site-wide top navigation bar used by every generated HTML page.

  One shared helper avoids drift between the per-page templates' navigation
  links. Pages pass their own identity and the filesystem depth from the
  site root so the `href`s resolve correctly — root-level pages use `""`,
  package detail pages under `packages/` use `"../"`.
  """

  @pages [
    {:home, "index.html", "Dashboard"},
    {:packages, "packages.html", "Packages"},
    {:clusters, "failure_clusters.html", "Failure clusters"},
    {:warnings, "warnings.html", "Warnings"},
    {:stats, "stats.html", "Stats"}
  ]

  @doc """
  Render the nav HTML. `current` is one of the page atoms above (or :none
  for pages like placeholders that don't correspond to a nav entry).
  `prefix` is the path prefix to reach the site root — `""` for root-level
  pages, `"../"` for pages one level deep.
  """
  @spec render(atom(), String.t()) :: iodata()
  def render(current, prefix \\ "") do
    links =
      @pages
      |> Enum.map(fn {id, href, label} ->
        active = if id == current, do: " nav-active", else: ""

        [
          ~s[<a class="nav-link#{active}" href="],
          prefix,
          href,
          ~s[">],
          label,
          ~s[</a>]
        ]
      end)

    [
      ~s[<nav class="site-nav"><div class="site-nav-inner">],
      ~s[<a class="site-nav-brand" href="],
      prefix,
      ~s[index.html">Nerves Compatibility</a>],
      ~s[<div class="site-nav-links">],
      links,
      ~s[</div></div></nav>],
      ~s[<div class="site-banner"><div class="site-banner-inner">],
      ~s[<strong>Experimental:</strong> Compatibility results are generated automatically and may be wrong. ],
      ~s[Spot a problem? <a href="https://github.com/fhunleth/nerves_compatibility/issues/new" target="_blank" rel="noopener">Open an issue on GitHub</a>.],
      ~s[</div></div>]
    ]
  end

  @doc """
  CSS for the nav PLUS the shared page shell (font, background, content
  container) so every page renders against the same chrome. Embedded inline
  in each template's <style> block — there's exactly one source of truth.

  Pages put their main content inside `<main class="page">` to get the
  1200px-wide centered container; the nav itself stretches full window
  width via the body background.
  """
  @spec css() :: String.t()
  def css() do
    """
    /* Page shell */
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { background: #f5f5f5; color: #1f2937; }
    body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; line-height: 1.55; padding-bottom: 48px; }
    main.page { max-width: 1200px; margin: 0 auto; padding: 0 20px; }
    main.page > h1 { margin-bottom: 6px; font-size: 1.75em; font-weight: 700; }
    main.page > .subtitle { color: #6b7280; margin-bottom: 22px; font-size: 0.95em; }
    main.page footer { margin-top: 40px; padding-top: 18px; border-top: 1px solid #e5e7eb; color: #6b7280; font-size: 0.85em; text-align: center; }
    a { color: #5e2ca5; }

    /* Top nav */
    .site-nav { background: #1e1b3a; color: #fff; padding: 10px 24px; }
    .site-nav-inner { max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; gap: 20px; flex-wrap: wrap; }
    .site-nav-brand { color: #fff; text-decoration: none; font-weight: 700; font-size: 1.05em; letter-spacing: 0.2px; }
    .site-nav-brand:hover { color: #c4b5fd; }
    .site-nav-links { display: flex; gap: 4px; flex-wrap: wrap; }
    .site-nav-links .nav-link { color: #cbd5e1; text-decoration: none; padding: 6px 12px; border-radius: 6px; font-size: 0.95em; transition: background 120ms; }
    .site-nav-links .nav-link:hover { background: rgba(255,255,255,0.08); color: #fff; }
    .site-nav-links .nav-link.nav-active { background: #5e2ca5; color: #fff; }

    /* Experimental banner */
    .site-banner { background: #fef3c7; color: #78350f; border-bottom: 1px solid #fcd34d; padding: 8px 24px; margin-bottom: 24px; }
    .site-banner-inner { max-width: 1200px; margin: 0 auto; font-size: 0.9em; }
    .site-banner a { color: #78350f; font-weight: 600; }
    """
  end
end
