defmodule OpentelemetryPlug do
  @moduledoc """
  Telemetry handler for creating OpenTelemetry Spans from Plug events.
  """

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span

  @doc """
  Attaches the OpentelemetryPlug handler to your Plug prefix events. This
  should be called from your application behaviour on startup.

  Example:

      OpentelemetryPlug.setup([])

  You may also supply the following options in the second argument:

    * `:time_unit` - a time unit used to convert the values of query phase
      timings, defaults to `:microsecond`. See `System.convert_time_unit/3`

    * `:span_prefix` - the first part of the span name, as a `String.t`,
      defaults to the concatenation of the event name with periods, e.g.
      `"my.plug.start"`.
  """
  def setup(config \\ []) do
    # register the tracer. just re-registers if called for multiple repos
    _ = OpenTelemetry.register_application_tracer(:opentelemetry_plug)

    :telemetry.attach({__MODULE__, :phoenix_tracer_router_start},
      [:phoenix, :router_dispatch, :start],
      &__MODULE__.handle_route/4,
      config)

    :telemetry.attach(
      {__MODULE__, :plug_tracer_router_start},
      [:plug, :router_dispatch, :start],
      &__MODULE__.handle_route/4,
      config)

    :telemetry.attach(
      {__MODULE__, :plug_tracer_start},
      [:plug_adapter, :call, :start],
      &__MODULE__.handle_start/4,
      config)

    :telemetry.attach(
      {__MODULE__, :plug_tracer_stop},
      [:plug_adapter, :call, :stop],
      &__MODULE__.handle_stop/4,
      config)

    :telemetry.attach(
      {__MODULE__, :plug_tracer_exception},
      [:plug_adapter, :call, :exception],
      &__MODULE__.handle_exception/4,
      config)
  end

  @doc false
  def handle_start(_, _measurements, %{conn: conn}, _config) do
    # TODO: add config for what paths are traced

    # setup OpenTelemetry context based on request headers
    :ot_propagation.http_extract(conn.req_headers)

    span_name = "HTTP " <> conn.method

    {_, adapter} = conn.adapter
    user_agent = header_or_empty(conn, "User-Agent")
    host = header_or_empty(conn, "Host")
    peer_ip = Map.get(Map.get(adapter, :peer_data), :address)

    attributes = [{"http.target", conn.request_path},
                  {"http.host",  conn.host},
                  {"http.scheme",  conn.scheme},
                  {"http.user_agent", user_agent},
                  {"http.method", conn.method},
                  {"net.peer.ip", to_string(:inet_parse.ntoa(peer_ip))},
                  {"net.peer.port", adapter.peer_data.port},
                  {"net.peer.name", host},
                  {"net.transport", "IP.TCP"},
                  {"net.host.ip", to_string(:inet_parse.ntoa(conn.remote_ip))},
                  {"net.host.port", conn.port} | optional_attributes(conn)
                  # {"net.host.name", HostName}
                 ]
    # TODO: Plug should provide a monotonic native time in measurements to use here
    # for the `start_time` option
    OpenTelemetry.Tracer.start_span(span_name, %{attributes: attributes})
  end

  @doc false
  def handle_route(_, _measurements, %{route: route}, _config) do
    # TODO: add config option to allow `conn.request_path` as span name
    OpenTelemetry.Span.update_name(route)
  end

  @doc false
  def handle_stop(_, _measurements, %{conn: conn}, _config) do
    OpenTelemetry.Span.set_attribute("http.status", conn.status)
    OpenTelemetry.Tracer.end_span()
  end

  @doc false
  def handle_exception(_, _measurements, %{conn: _conn}, _config) do
    OpenTelemetry.Span.set_status(OpenTelemetry.status('UnknownError', "unknown error"))
    OpenTelemetry.Tracer.end_span()
  end

  defp header_or_empty(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        ""
      [host | _] ->
        host
    end
  end

  defp optional_attributes(conn) do
    # for some reason Elixir removed Enum.filter_map in 1.5
    # so just using Erlang's list module
    :lists.filtermap(fn({attr, fun}) ->
      case fun.(conn) do
        nil ->
          false;
        value ->
          {true, {attr, value}}
      end
    end, [{"http.client_ip", &client_ip/1},
          {"http.server_name", &server_name/1}])
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "X-Forwarded-For") do
      [] ->
        nil
      [host | _] ->
        host
    end
  end

  defp server_name(_) do
    Application.get_env(OpentelemetryPlug, :server_name, nil)
  end
end
