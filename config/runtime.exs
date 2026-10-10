import Config

if config_env() == :prod do
  # Runtime configuration for production releases
  http_port = System.get_env("VARCO_HTTP_PORT", "8080") |> String.to_integer()
  https_port = System.get_env("VARCO_HTTPS_PORT", "8443") |> String.to_integer()
  admin_port = System.get_env("VARCO_ADMIN_PORT", "9000") |> String.to_integer()

  config :varco,
    http_port: http_port,
    https_port: https_port,
    admin_port: admin_port,
    start_servers: true
end
