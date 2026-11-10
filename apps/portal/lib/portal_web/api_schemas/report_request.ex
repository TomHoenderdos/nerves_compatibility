defmodule PortalWeb.ApiSchemas.ReportRequest do
  @moduledoc "The body of `POST /api/precompiled/reports`."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @line %Schema{
    type: :object,
    additionalProperties: false,
    required: [:name, :version, :status, :reason_code],
    properties: %{
      name: %Schema{type: :string, description: "Hex package name."},
      version: %Schema{type: :string},
      status: %Schema{type: :string, enum: ["hit", "miss", "fail"]},
      reason_code: %Schema{type: :string, description: "A code from the client's fixed table."},
      reason_args: %Schema{
        type: :array,
        nullable: true,
        maxItems: 8,
        items: %Schema{type: :string, pattern: "^[A-Za-z0-9_.+:-]{0,64}$"}
      },
      reason: %Schema{
        type: :string,
        nullable: true,
        description: "The code's template, rendered; cut at 300 characters."
      }
    }
  }

  @lock %Schema{
    type: :object,
    additionalProperties: false,
    required: [:name, :version, :checksum],
    properties: %{
      name: %Schema{type: :string},
      version: %Schema{type: :string},
      checksum: %Schema{
        type: :string,
        pattern: "^[0-9a-fA-F]{64}$",
        description: "Outer checksum."
      }
    }
  }

  OpenApiSpex.schema(
    %{
      title: "ReportRequest",
      description:
        "What `mix precompiled.report` sends: each candidate's line, the toolchain, and the " <>
          "public Hex lock entries of the candidates and their dependencies. Unknown fields at any " <>
          "level are refused.",
      type: :object,
      additionalProperties: false,
      required: [:format, :client, :elixir, :otp, :os, :target, :lines, :lock],
      properties: %{
        format: %Schema{type: :integer, minimum: 1},
        client: %Schema{type: :string, description: "The client library version."},
        built_at: %Schema{type: :string, format: :"date-time", nullable: true},
        elixir: %Schema{type: :string},
        otp: %Schema{type: :integer, minimum: 20, maximum: 99},
        os: %Schema{
          type: :object,
          additionalProperties: false,
          required: [:family, :arch],
          properties: %{
            family: %Schema{type: :string, enum: ["unix", "win32"]},
            arch: %Schema{type: :string, pattern: "^[a-z0-9_.-]{1,64}$"}
          }
        },
        target: %Schema{type: :string, pattern: "^[a-z0-9_]{1,64}$"},
        system: %Schema{type: :string, nullable: true, pattern: "^[a-z][a-z0-9_]{0,63}$"},
        system_version: %Schema{type: :string, nullable: true},
        lines: %Schema{type: :array, maxItems: 500, items: @line},
        lock: %Schema{type: :array, maxItems: 1000, items: @lock},
        contact: %Schema{type: :string, nullable: true, maxLength: 100}
      },
      example: %{
        "format" => 1,
        "client" => "0.4.0",
        "elixir" => "1.20.3",
        "otp" => 29,
        "os" => %{"family" => "unix", "arch" => "aarch64-apple-darwin"},
        "target" => "host",
        "lines" => [
          %{
            "name" => "jason",
            "version" => "1.4.5",
            "status" => "miss",
            "reason_code" => "not_built_version",
            "reason_args" => ["1.4.5"],
            "reason" => "not built for 1.4.5"
          }
        ],
        "lock" => [
          %{"name" => "jason", "version" => "1.4.5", "checksum" => String.duplicate("a", 64)}
        ]
      }
    },
    struct?: false
  )
end
