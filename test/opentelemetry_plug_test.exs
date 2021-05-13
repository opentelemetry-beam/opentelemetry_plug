defmodule OpentelemetryPlugTest do
  use ExUnit.Case

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

  test "creates span and adds propagation headers" do
    assert {200, headers, "Hello world"} = request(:get, "/hello/world")
    assert {"traceparent", _} = List.keyfind(headers, "traceparent", 0)
    assert_receive {:span, _}, 5000
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
