defmodule Site.Nav do
  @moduledoc """
  Renders the site-wide top navigation bar used by every generated HTML page.

  One shared helper avoids drift between the per-page templates' navigation
  links. Pages pass their own identity and the filesystem depth from the
  site root so the `href`s resolve correctly — root-level pages use `""`,
  package detail pages under `packages/` use `"../"`.
  """

  @pages [
    {:home, "/site/index.html", "Dashboard"},
    {:packages, "/site/packages.html", "Packages"},
    {:request_scan, "/request-scan", "Request scan"},
    {:clusters, "/site/failure_clusters.html", "Failure clusters"},
    {:warnings, "/site/warnings.html", "Warnings"},
    {:stats, "/site/stats.html", "Stats"}
  ]

  @doc """
  Render the nav HTML. `current` is one of the page atoms above (or :none
  for pages like placeholders that don't correspond to a nav entry).
  `prefix` is accepted for compatibility with older callers. Navigation links
  are absolute so generated pages work consistently when served by Phoenix.
  """
  @spec render(atom(), String.t()) :: iodata()
  def render(current, _prefix \\ "") do
    links =
      @pages
      |> Enum.map(fn {id, href, label} ->
        active = if id == current, do: " nav-active", else: ""

        [
          ~s[<a class="nav-link#{active}" href="],
          href,
          ~s[">],
          label,
          ~s[</a>]
        ]
      end)

    [
      ~s[<nav class="site-nav"><div class="site-nav-inner">],
      ~s[<a class="site-nav-brand" href="],
      ~s[/site/index.html">Nerves Compatibility</a>],
      ~s[<div class="site-nav-links">],
      links,
      theme_toggle(),
      auth_links(),
      ~s[</div></div></nav>],
      ~s[<div class="site-banner"><div class="site-banner-inner">],
      ~s[<strong>Experimental:</strong> Compatibility results are generated automatically and may be wrong. ],
      ~s[Spot a problem? <a href="https://github.com/fhunleth/nerves_compatibility/issues/new" target="_blank" rel="noopener">Open an issue on GitHub</a>.],
      ~s[</div></div>],
      theme_script()
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
    .site-nav-links { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
    .site-nav-links .nav-link { color: #cbd5e1; text-decoration: none; padding: 6px 12px; border-radius: 6px; font-size: 0.95em; transition: background 120ms; }
    .site-nav-links .nav-link:hover { background: rgba(255,255,255,0.08); color: #fff; }
    .site-nav-links .nav-link.nav-active { background: #5e2ca5; color: #fff; }
    .theme-toggle { position: relative; display: flex; align-items: center; width: 102px; height: 40px; margin-left: 8px; border: 2px solid #334155; background: #334155; border-radius: 999px; overflow: hidden; }
    .theme-toggle-thumb { position: absolute; top: 0; bottom: 0; left: 0; width: 33.333%; border: 1px solid #e5e7eb; background: #fff; border-radius: 999px; filter: brightness(1.2); transition: left 150ms ease; }
    .theme-toggle button { position: relative; z-index: 1; width: 33.333%; height: 100%; display: grid; place-items: center; border: 0; background: transparent; color: #e5e7eb; cursor: pointer; }
    .theme-toggle button:hover { color: #fff; }
    .theme-toggle svg { width: 16px; height: 16px; fill: currentColor; }
    html[data-theme="light"] .theme-toggle-thumb { left: 33.333%; }
    html[data-theme="dark"] .theme-toggle-thumb { left: 66.666%; }
    .site-nav-auth { display: flex; align-items: center; gap: 4px; margin-left: 8px; }
    .site-avatar { width: 34px; height: 34px; border-radius: 999px; display: inline-grid; place-items: center; color: #1e1b3a; background: #fff; border: 1px solid rgba(255,255,255,0.55); font-weight: 800; text-decoration: none; }
    .site-avatar:hover { color: #5e2ca5; }
    .site-avatar svg { width: 16px; height: 16px; fill: currentColor; }

    /* Experimental banner */
    .site-banner { background: #fef3c7; color: #78350f; border-bottom: 1px solid #fcd34d; padding: 8px 24px; margin-bottom: 24px; }
    .site-banner-inner { max-width: 1200px; margin: 0 auto; font-size: 0.9em; }
    .site-banner a { color: #78350f; font-weight: 600; }

    html[data-theme="dark"], html[data-theme="dark"] body {
      background: #111827 !important;
      color: #e5e7eb !important;
      color-scheme: dark;
    }

    html[data-theme="dark"] main.page,
    html[data-theme="dark"] main.page > h1,
    html[data-theme="dark"] h1,
    html[data-theme="dark"] h2,
    html[data-theme="dark"] h3 {
      color: #f9fafb !important;
    }

    html[data-theme="dark"] main.page > .subtitle,
    html[data-theme="dark"] main.page footer,
    html[data-theme="dark"] .summary,
    html[data-theme="dark"] .summary-label,
    html[data-theme="dark"] .result-meta,
    html[data-theme="dark"] .cluster-meta,
    html[data-theme="dark"] .cluster-hint,
    html[data-theme="dark"] .warn-hint,
    html[data-theme="dark"] .empty,
    html[data-theme="dark"] .info-label,
    html[data-theme="dark"] .pager .pager-info,
    html[data-theme="dark"] [style*="color: #6b7280"],
    html[data-theme="dark"] [style*="color:#6b7280"],
    html[data-theme="dark"] [style*="color: #666"],
    html[data-theme="dark"] [style*="color: #555"],
    html[data-theme="dark"] [style*="color: #4b5563"] {
      color: #9ca3af !important;
    }

    html[data-theme="dark"] a,
    html[data-theme="dark"] .pkg-link,
    html[data-theme="dark"] .top-list-link,
    html[data-theme="dark"] details summary,
    html[data-theme="dark"] [style*="color: #5e2ca5"] {
      color: #c4b5fd !important;
    }

    html[data-theme="dark"] .summary-section,
    html[data-theme="dark"] .summary-card,
    html[data-theme="dark"] .top-list,
    html[data-theme="dark"] .filters,
    html[data-theme="dark"] table,
    html[data-theme="dark"] .cluster,
    html[data-theme="dark"] .warn,
    html[data-theme="dark"] .stat-card,
    html[data-theme="dark"] .stats-section,
    html[data-theme="dark"] .package-info,
    html[data-theme="dark"] .systems-section,
    html[data-theme="dark"] details.pkg-detail,
    html[data-theme="dark"] .search-results,
    html[data-theme="dark"] .empty,
    html[data-theme="dark"] [style*="background: white"],
    html[data-theme="dark"] [style*="background:#fff"],
    html[data-theme="dark"] [style*="background: #fff"] {
      background: #1f2937 !important;
      border-color: #374151 !important;
      color: #e5e7eb !important;
      box-shadow: none !important;
    }

    html[data-theme="dark"] [style*="background: #f9fafb"],
    html[data-theme="dark"] [style*="background-color: #f9fafb"],
    html[data-theme="dark"] [style*="background-color: #f3f4f6"],
    html[data-theme="dark"] .top-list-item:hover,
    html[data-theme="dark"] .search-result-item:hover,
    html[data-theme="dark"] th {
      background: #111827 !important;
      color: #e5e7eb !important;
    }

    html[data-theme="dark"] td,
    html[data-theme="dark"] th,
    html[data-theme="dark"] .top-list-item,
    html[data-theme="dark"] .search-result-item,
    html[data-theme="dark"] main.page footer,
    html[data-theme="dark"] .pkg-row {
      border-color: #374151 !important;
    }

    html[data-theme="dark"] input,
    html[data-theme="dark"] select,
    html[data-theme="dark"] textarea,
    html[data-theme="dark"] .search-input {
      background: #111827 !important;
      border-color: #4b5563 !important;
      color: #f9fafb !important;
    }

    html[data-theme="dark"] input::placeholder,
    html[data-theme="dark"] textarea::placeholder {
      color: #6b7280 !important;
    }

    html[data-theme="dark"] .site-banner {
      background: #422006 !important;
      border-bottom-color: #92400e !important;
      color: #fde68a !important;
    }

    html[data-theme="dark"] .site-banner a {
      color: #fef3c7 !important;
    }

    html[data-theme="dark"] pre.log,
    html[data-theme="dark"] code {
      background-color: #0f172a;
      color: #e5e7eb;
    }

    html[data-theme="dark"] .sys-chip.unknown,
    html[data-theme="dark"] .lang-tag.none,
    html[data-theme="dark"] .status-badge.unknown,
    html[data-theme="dark"] .status-badge.skipped,
    html[data-theme="dark"] .overall-status.unknown,
    html[data-theme="dark"] .meta-pill {
      background: #374151 !important;
      border-color: #4b5563 !important;
      color: #e5e7eb !important;
    }

    @media (prefers-color-scheme: dark) {
      html:not([data-theme="light"]), html:not([data-theme="light"]) body {
        background: #111827 !important;
        color: #e5e7eb !important;
        color-scheme: dark;
      }

      html:not([data-theme="light"]) main.page,
      html:not([data-theme="light"]) main.page > h1,
      html:not([data-theme="light"]) h1,
      html:not([data-theme="light"]) h2,
      html:not([data-theme="light"]) h3 {
        color: #f9fafb !important;
      }

      html:not([data-theme="light"]) main.page > .subtitle,
      html:not([data-theme="light"]) main.page footer,
      html:not([data-theme="light"]) .summary,
      html:not([data-theme="light"]) .summary-label,
      html:not([data-theme="light"]) .result-meta,
      html:not([data-theme="light"]) .cluster-meta,
      html:not([data-theme="light"]) .cluster-hint,
      html:not([data-theme="light"]) .warn-hint,
      html:not([data-theme="light"]) .empty,
      html:not([data-theme="light"]) .info-label,
      html:not([data-theme="light"]) .pager .pager-info,
      html:not([data-theme="light"]) [style*="color: #6b7280"],
      html:not([data-theme="light"]) [style*="color:#6b7280"],
      html:not([data-theme="light"]) [style*="color: #666"],
      html:not([data-theme="light"]) [style*="color: #555"],
      html:not([data-theme="light"]) [style*="color: #4b5563"] {
        color: #9ca3af !important;
      }

      html:not([data-theme="light"]) a,
      html:not([data-theme="light"]) .pkg-link,
      html:not([data-theme="light"]) .top-list-link,
      html:not([data-theme="light"]) details summary,
      html:not([data-theme="light"]) [style*="color: #5e2ca5"] {
        color: #c4b5fd !important;
      }

      html:not([data-theme="light"]) .summary-section,
      html:not([data-theme="light"]) .summary-card,
      html:not([data-theme="light"]) .top-list,
      html:not([data-theme="light"]) .filters,
      html:not([data-theme="light"]) table,
      html:not([data-theme="light"]) .cluster,
      html:not([data-theme="light"]) .warn,
      html:not([data-theme="light"]) .stat-card,
      html:not([data-theme="light"]) .stats-section,
      html:not([data-theme="light"]) .package-info,
      html:not([data-theme="light"]) .systems-section,
      html:not([data-theme="light"]) details.pkg-detail,
      html:not([data-theme="light"]) .search-results,
      html:not([data-theme="light"]) .empty,
      html:not([data-theme="light"]) [style*="background: white"],
      html:not([data-theme="light"]) [style*="background:#fff"],
      html:not([data-theme="light"]) [style*="background: #fff"] {
        background: #1f2937 !important;
        border-color: #374151 !important;
        color: #e5e7eb !important;
        box-shadow: none !important;
      }

      html:not([data-theme="light"]) [style*="background: #f9fafb"],
      html:not([data-theme="light"]) [style*="background-color: #f9fafb"],
      html:not([data-theme="light"]) [style*="background-color: #f3f4f6"],
      html:not([data-theme="light"]) .top-list-item:hover,
      html:not([data-theme="light"]) .search-result-item:hover,
      html:not([data-theme="light"]) th {
        background: #111827 !important;
        color: #e5e7eb !important;
      }

      html:not([data-theme="light"]) td,
      html:not([data-theme="light"]) th,
      html:not([data-theme="light"]) .top-list-item,
      html:not([data-theme="light"]) .search-result-item,
      html:not([data-theme="light"]) main.page footer,
      html:not([data-theme="light"]) .pkg-row {
        border-color: #374151 !important;
      }

      html:not([data-theme="light"]) input,
      html:not([data-theme="light"]) select,
      html:not([data-theme="light"]) textarea,
      html:not([data-theme="light"]) .search-input {
        background: #111827 !important;
        border-color: #4b5563 !important;
        color: #f9fafb !important;
      }

      html:not([data-theme="light"]) input::placeholder,
      html:not([data-theme="light"]) textarea::placeholder {
        color: #6b7280 !important;
      }

      html:not([data-theme="light"]) .site-banner {
        background: #422006 !important;
        border-bottom-color: #92400e !important;
        color: #fde68a !important;
      }

      html:not([data-theme="light"]) .site-banner a {
        color: #fef3c7 !important;
      }

      html:not([data-theme="light"]) pre.log,
      html:not([data-theme="light"]) code {
        background-color: #0f172a;
        color: #e5e7eb;
      }

      html:not([data-theme="light"]) .sys-chip.unknown,
      html:not([data-theme="light"]) .lang-tag.none,
      html:not([data-theme="light"]) .status-badge.unknown,
      html:not([data-theme="light"]) .status-badge.skipped,
      html:not([data-theme="light"]) .overall-status.unknown,
      html:not([data-theme="light"]) .meta-pill {
        background: #374151 !important;
        border-color: #4b5563 !important;
        color: #e5e7eb !important;
      }
    }
    """
  end

  defp theme_toggle do
    """
    <div class="theme-toggle" aria-label="Theme selector">
      <div class="theme-toggle-thumb" aria-hidden="true"></div>
      <button type="button" aria-label="Use system theme" data-phx-theme="system">
        <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h7A2.5 2.5 0 0 1 16 5.5v5A2.5 2.5 0 0 1 13.5 13h-7A2.5 2.5 0 0 1 4 10.5v-5Zm1.5 0v5A1 1 0 0 0 6.5 11.5h7a1 1 0 0 0 1-1v-5a1 1 0 0 0-1-1h-7a1 1 0 0 0-1 1ZM7 15h6v1.5H7V15Z" /></svg>
      </button>
      <button type="button" aria-label="Use light theme" data-phx-theme="light">
        <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 4.5a.75.75 0 0 1-.75-.75V2h1.5v1.75A.75.75 0 0 1 10 4.5Zm0 13.5H9.25v-1.75h1.5V18H10ZM4.5 10a.75.75 0 0 1-.75.75H2v-1.5h1.75A.75.75 0 0 1 4.5 10Zm13.5.75h-1.75v-1.5H18v1.5ZM5.05 6.11 3.82 4.88l1.06-1.06 1.23 1.23-1.06 1.06Zm10.07 10.07-1.23-1.23 1.06-1.06 1.23 1.23-1.06 1.06Zm-10.24 0-1.06-1.06 1.23-1.23 1.06 1.06-1.23 1.23ZM14.95 6.11l-1.06-1.06 1.23-1.23 1.06 1.06-1.23 1.23ZM10 6.25A3.75 3.75 0 1 1 10 13.75 3.75 3.75 0 0 1 10 6.25Z" /></svg>
      </button>
      <button type="button" aria-label="Use dark theme" data-phx-theme="dark">
        <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M15.75 12.2A6.75 6.75 0 0 1 7.8 4.25 6.76 6.76 0 1 0 15.75 12.2Z" /></svg>
      </button>
    </div>
    """
  end

  defp auth_links do
    """
    <div class="site-nav-auth">
      <a class="site-avatar" href="/login" aria-label="Login">
        <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-7 8a7 7 0 1 1 14 0H3Z" /></svg>
      </a>
      <a class="nav-link" href="/login">Login</a>
      <a class="nav-link" href="/register">Register</a>
    </div>
    """
  end

  defp theme_script do
    """
    <script>
      (() => {
        const setTheme = (theme) => {
          if (theme === "system") {
            localStorage.removeItem("phx:theme");
            document.documentElement.removeAttribute("data-theme");
          } else {
            localStorage.setItem("phx:theme", theme);
            document.documentElement.setAttribute("data-theme", theme);
          }
        };

        if (!document.documentElement.hasAttribute("data-theme")) {
          setTheme(localStorage.getItem("phx:theme") || "system");
        }

        window.addEventListener("storage", (event) => {
          if (event.key === "phx:theme") {
            setTheme(event.newValue || "system");
          }
        });

        document.querySelectorAll("[data-phx-theme]").forEach((button) => {
          button.addEventListener("click", () => setTheme(button.dataset.phxTheme));
        });
      })();
    </script>
    """
  end
end
