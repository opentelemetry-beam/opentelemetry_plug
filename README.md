# OpentelemetryPlug

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `opentelemetry_plug` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:opentelemetry_plug, "~> 0.1.0"}
  ]
end
```

OpentelemetryPlug requires following Plug.Telemetry configuration:
```elixir
plug Plug.Telemetry, event_prefix: [:plug_adapter, :call]
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/opentelemetry_plug](https://hexdocs.pm/opentelemetry_plug).

