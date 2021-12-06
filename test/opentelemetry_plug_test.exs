defmodule OpentelemetryPlugTest do
  use ExUnit.Case, async: false
  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  for r <- [:event, :status] do
    Record.defrecord(
      r,
      Record.extract(r, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    )
  end

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

    for attr <- @default_attrs do
      assert List.keymember?(attrs, attr, 0)
    end
  end

  test "basic http attributes are set" do
    # no query string
    assert {200, _, "Hello world"} = request(:get, "/hello/world")
    assert_receive {:span, span(name: "/hello/:foo", attributes: attrs)}, 5000

    assert "GET" == attrs[:"http.method"]
    assert :http == attrs[:"http.scheme"]
    assert host() == attrs[:"http.host"]
    assert "/hello/world" == attrs[:"http.target"]
    assert "hackney" <> _ = attrs[:"http.user_agent"]

    # query string
    assert {200, _, "Hello world"} = request(:get, "/hello/world?param=one&other=42")
    assert_receive {:span, span(name: "/hello/:foo", attributes: attrs)}, 5000

    assert "/hello/world?param=one&other=42" == attrs[:"http.target"]
  end

  test "adds optional attributes when available" do
    Application.put_env(:opentelemetry_plug, :server_name, "example.com")

    assert {200, _headers, _body} =
             request(:get, "/hello/world", [{"x-forwarded-for", "1.1.1.1"}])

    assert_receive {:span, span(attributes: attrs)}, 5000

    assert List.keymember?(attrs, :"http.client_ip", 0)
    assert List.keymember?(attrs, :"http.server_name", 0)
  end

  test "records exceptions" do
    assert {500, _, _} = request(:get, "/hello/crash")
    assert_receive {:span, span(attributes: attrs, status: span_status, events: events)}, 5000

    assert {:"http.status_code", 500} = List.keyfind(attrs, :"http.status_code", 0)
    assert status(code: :error, message: _) = span_status
    assert [event(name: "exception", attributes: evt_attrs)] = events

    for key <- ~w(exception.type exception.message exception.stacktrace) do
      assert List.keymember?(evt_attrs, key, 0)
    end
  end

  test "sets span status on non-successful status codes" do
    assert {400, _, _} = request(:get, "/hello/bad-request")
    assert_receive {:span, span(attributes: attrs, status: span_status)}, 5000
    assert {:"http.status_code", 400} = List.keyfind(attrs, :"http.status_code", 0)
    assert status(code: :error, message: _) = span_status
  end

  test "gracefully handles nested routers" do
    assert {200, _, _} = request(:get, "/hello/nested")

    assert_receive {:span,
                    span(name: "/hello/nested/*glob/", parent_span_id: parent, trace_id: trace_id)},
                   5000

    assert_receive {:span,
                    span(name: "/hello/nested/*glob", span_id: ^parent, trace_id: ^trace_id)},
                   5000
  end

  defp host do
    :ranch.info(MyRouter.HTTP) |> Keyword.fetch!(:ip) |> :inet.ntoa() |> to_string()
  end

  defp base_url do
    port = :ranch.info(MyRouter.HTTP) |> Keyword.fetch!(:port)
    "http://#{host()}:#{port}"
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

defmodule MyRouter.NestedRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  match "/" do
    send_resp(conn, 200, "Hello from nested")
  end
end

defmodule MyRouter do
  use Plug.Router

  plug :match
  plug OpentelemetryPlug.Propagation
  plug :dispatch

  forward "/hello/nested", to: MyRouter.NestedRouter

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
