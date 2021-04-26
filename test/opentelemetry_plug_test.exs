defmodule OpentelemetryPlugTest do
  use ExUnit.Case

  setup_all do
    OpentelemetryPlug.setup([])

    {:ok, _} = Plug.Cowboy.http(MyRouter, [], ip: {127, 0, 0, 1}, port: 0)

    on_exit(fn ->
      :ok = Plug.Cowboy.shutdown(MyRouter.HTTP)
    end)
  end

  test "creates span" do
    assert {200, _, "Hello world"} = request(:get, "/hello/world")
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

defmodule MyPlug do
  import Plug.Conn
  require OpenTelemetry.Tracer

  def init(options) do
    options
  end

  def call(conn, _opts) do
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

defmodule MyRouter do
  use Plug.Router

  plug :match
  plug Plug.Telemetry, event_prefix: [:plug_adapter, :call]
  plug :dispatch

  forward "/hello/:foo", to: MyPlug
end
