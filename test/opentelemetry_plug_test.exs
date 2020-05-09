defmodule OpentelemetryPlugTest do
  use ExUnit.Case
  use Plug.Test

  test "creates span" do
    conn = conn(:get, "/hello/world")

    OpentelemetryPlug.setup([:my, :plug], [])
    conn = MyRouter.call(conn, [])

    assert conn.state == :sent
    assert conn.status == 200
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
  plug :dispatch

  forward "/hello/:foo", to: MyPlug
end
