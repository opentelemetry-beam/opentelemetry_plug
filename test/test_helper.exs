ExUnit.start()

Application.ensure_all_started(:hackney)
Application.ensure_all_started(:opentelemetry_api)
Application.ensure_all_started(:opentelemetry)
