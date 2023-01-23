import Config

config :opentelemetry,
  #sampler: {:always_on, %{}},
  #tracer: :otel_tracer_default,
  span_processor: :batch,
  traces_exporter: {:otel_exporter_stdout, []}
  #processors: [
  #  otel_batch_processor: %{scheduled_delay_ms: 1, exporter: :undefined}
  #]
