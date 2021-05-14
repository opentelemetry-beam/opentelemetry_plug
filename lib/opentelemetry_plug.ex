defmodule OpentelemetryPlug do
  @moduledoc """
  Telemetry handler for creating OpenTelemetry Spans from Plug events.
  """

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span

  defmodule Propagation do
    @moduledoc """
    Adds OpenTelemetry context propagation headers to the Plug response
    """

    @behaviour Plug
    import Plug.Conn, only: [register_before_send: 2, merge_resp_headers: 2]

    @impl true
    def init(opts) do
      opts
    end

    @impl true
    def call(conn, _opts) do
      register_before_send(conn, &merge_resp_headers(&1, :otel_propagator.text_map_inject([])))
    end
  end

  @doc """
  Attaches the OpentelemetryPlug handler to your Plug prefix events. This
  should be called from your application behaviour on startup.

  Example:

      OpentelemetryPlug.setup()

  You may also supply the following options as an optional argument:

    * `:event_prefix` - the
  """
  def setup(config \\ []) do
    # register the tracer. just re-registers if called for multiple repos
    _ = OpenTelemetry.register_application_tracer(:opentelemetry_plug)

    # :telemetry.attach_many(
    #   {__MODULE__, :debug},
    #   [
    #     [:plug, :router_dispatch, :start],
    #     [:plug, :router_dispatch, :stop],
    #     [:plug, :router_dispatch, :exception]
    #   ],
    #   &IO.inspect({&1, &2, &3, &4}, label: Enum.join(&1, ".")),
    #   %{}
    # )

    :telemetry.attach(
      {__MODULE__, :plug_router_start},
      [:plug, :router_dispatch, :start],
      &__MODULE__.handle_start/4,
      config
    )

    :telemetry.attach(
      {__MODULE__, :plug_router_stop},
      [:plug, :router_dispatch, :stop],
      &__MODULE__.handle_stop/4,
      config
    )

    :telemetry.attach(
      {__MODULE__, :plug_router_exception},
      [:plug, :router_dispatch, :exception],
      &__MODULE__.handle_exception/4,
      config
    )
  end

  @doc false
  def handle_start(_, _measurements, %{conn: conn, route: route}, _config) do
    save_parent_ctx()
    # setup OpenTelemetry context based on request headers
    :otel_propagator.text_map_extract(conn.req_headers)

    span_name = "#{conn.method} #{route}"

    peer_data = Plug.Conn.get_peer_data(conn)

    user_agent = header_or_empty(conn, "User-Agent")
    host = header_or_empty(conn, "Host")
    peer_ip = Map.get(peer_data, :address)

    attributes = [
      {"http.target", conn.request_path},
      {"http.host", conn.host},
      {"http.scheme", conn.scheme},
      {"http.flavor", http_flavor(conn.adapter)},
      {"http.user_agent", user_agent},
      {"http.method", conn.method},
      {"net.peer.ip", to_string(:inet_parse.ntoa(peer_ip))},
      {"net.peer.port", peer_data.port},
      {"net.peer.name", host},
      {"net.transport", "IP.TCP"},
      {"net.host.ip", to_string(:inet_parse.ntoa(conn.remote_ip))},
      {"net.host.port", conn.port}
      | optional_attributes(conn)
    ]

    # TODO: Plug should provide a monotonic native time in measurements to use here
    # for the `start_time` option
    span_ctx =
      OpenTelemetry.Tracer.start_span(span_name, %{attributes: attributes, kind: :server})

    OpenTelemetry.Tracer.set_current_span(span_ctx)
  end

  @doc false
  def handle_stop(_, _measurements, %{conn: conn}, _config) do
    if in_span?() do
      OpenTelemetry.Tracer.set_attribute("http.status_code", conn.status)
      OpenTelemetry.Tracer.end_span()
      restore_parent_ctx()
    end
  end

  @doc false
  def handle_exception(_, _measurements, metadata, _config) do
    if in_span?() do
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      exception = Exception.normalize(kind, reason, stacktrace)

      OpenTelemetry.Span.record_exception(
        OpenTelemetry.Tracer.current_span_ctx(),
        exception,
        stacktrace
      )

      OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, Exception.message(exception)))
      OpenTelemetry.Tracer.set_attribute("http.status_code", 500)
      OpenTelemetry.Tracer.end_span()
      restore_parent_ctx()
    end
  end

  defp in_span?, do: OpenTelemetry.Tracer.current_span_ctx() != :undefined

  defp header_or_empty(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        ""

      [host | _] ->
        host
    end
  end

  defp optional_attributes(conn) do
    [{"http.client_ip", &client_ip/1}, {"http.server_name", &server_name/1}]
    |> Enum.map(fn {attr, fun} -> {attr, fun.(conn)} end)
    |> Enum.reject(&is_nil(elem(&1, 1)))
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        nil

      [host | _] ->
        host
    end
  end

  defp server_name(_) do
    Application.get_env(:opentelemetry_plug, :server_name, nil)
  end

  defp http_flavor({_adapter_name, meta}) do
    case Map.get(meta, :version) do
      :"HTTP/1.0" -> :"1.0"
      :"HTTP/1.1" -> :"1.1"
      :"HTTP/2.0" -> :"2.0"
      :SPDY -> :SPDY
      :QUIC -> :QUIC
      nil -> ""
    end
  end

  @ctx_key {__MODULE__, :parent_ctx}
  defp save_parent_ctx() do
    ctx = OpenTelemetry.Tracer.current_span_ctx()
    Process.put(@ctx_key, ctx)
  end

  defp restore_parent_ctx() do
    ctx = Process.get(@ctx_key, :undefined)
    Process.delete(@ctx_key)
    OpenTelemetry.Tracer.set_current_span(ctx)
  end
end
