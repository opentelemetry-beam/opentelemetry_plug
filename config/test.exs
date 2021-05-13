import Config

config :opentelemetry,
  sampler: {:always_on, %{}},
  tracer: :otel_tracer_default,
  processors: [
    otel_batch_processor: %{scheduled_delay_ms: 1, exporter: :undefined}
  ]
