defmodule OpentelemetryPlugTest do
  use ExUnit.Case, async: false
  require Record

  for r <- [:span, :event] do
    Record.defrecord(
      r,
      Record.extract(r, from_lib: "opentelemetry/include/otel_span.hrl")
    )
  end

  Record.defrecord(:status, Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl"))

  setup_all do
    OpentelemetryPlug.setup()

    {:ok, _} = Plug.Cowboy.http(MyRouter, [], ip: {127, 0, 0, 1}, port: 0)

    on_exit(fn ->
      :ok = Plug.Cowboy.shutdown(MyRouter.HTTP)
    end)
  end

  setup do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
  end

  @default_attrs ~w(
    http.flavor
    http.method
    http.route
    http.scheme
    http.status_code
    http.target
    http.user_agent
    net.host.ip
    net.host.port
    net.peer.ip
    net.peer.name
    net.peer.port
    net.transport
  )a

  test "creates span and adds propagation headers" do
    assert {200, headers, "Hello world"} = request(:get, "/hello/world")

    assert List.keymember?(headers, "traceparent", 0)
    assert_receive {:span, span(name: "/hello/:foo", attributes: attrs)}, 5000
    attrs_map = elem(attrs, 4)

    for attr <- @default_attrs do
      assert Map.has_key?(attrs_map, attr)
    end
  end

  test "adds optional attributes when available" do
    Application.put_env(:opentelemetry_plug, :server_name, "example.com")

    assert {200, _headers, _body} =
             request(:get, "/hello/world", [{"x-forwarded-for", "1.1.1.1"}])

    assert_receive {:span, span(attributes: attrs)}, 5000
    attrs_map = elem(attrs, 4)

    assert Map.has_key?(attrs_map, :"http.client_ip")
    assert Map.has_key?(attrs_map, :"http.server_name")
  end

  test "records exceptions" do
    assert {500, _, _} = request(:get, "/hello/crash")
    assert_receive {:span, span(attributes: attrs, status: span_status, events: events)}, 5000

    assert 500 = Map.get(elem(attrs, 4), :"http.status_code")
    assert status(code: :error, message: _) = span_status
    event_extracted = List.first(elem(events, 5))
    assert event(name: "exception", attributes: evt_attrs) = event_extracted

    evt_attrs_map = elem(evt_attrs, 4)

    for key <- ~w(exception.type exception.message exception.stacktrace) do
      assert Map.has_key?(evt_attrs_map, key)
    end
  end

  test "sets span status on non-successful status codes" do
    assert {400, _, _} = request(:get, "/hello/bad-request")
    assert_receive {:span, span(attributes: attrs, status: span_status)}, 5000
    assert 400 = Map.get(elem(attrs, 4), :"http.status_code")
    assert status(code: :error, message: _) = span_status
  end

  defp base_url do
    info = :ranch.info(MyRouter.HTTP)
    port = Keyword.fetch!(info, :port)
    ip = Keyword.fetch!(info, :ip)
    "http://#{:inet.ntoa(ip)}:#{port}"
  end

  defp request(:head = verb, path) do
    {:ok, status, headers} = :hackney.request(verb, base_url() <> path, [], "", [])
    {status, headers, nil}
  end

  defp request(verb, path, headers \\ [], body \\ "") do
    case :hackney.request(verb, base_url() <> path, headers, body, []) do
      {:ok, status, headers, client} ->
        {:ok, body} = :hackney.body(client)
        :hackney.close(client)
        {status, headers, body}

      {:error, _} = error ->
        error
    end
  end
end

defmodule MyRouter do
  use Plug.Router

  plug :match
  plug OpentelemetryPlug.Propagation
  plug :dispatch

  match "/hello/crash" do
    _ = conn
    raise ArgumentError
  end

  match "/hello/bad-request" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "bad request")
  end

  match "/hello/:foo" do
    case OpenTelemetry.Tracer.current_span_ctx() do
      :undefined ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "no span context")

      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "Hello world")
    end
  end
end
