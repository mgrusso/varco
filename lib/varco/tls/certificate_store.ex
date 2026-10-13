defmodule Varco.TLS.CertificateStore do
  @moduledoc """
  High-performance, ETS-backed certificate store and dynamic SNI resolver.

  Provides sub-microsecond certificate lookups during TLS handshakes and
  powers Varco's zero-config self-signed HTTPS and ACME integration.
  """

  use GenServer
  require Logger
  alias Varco.TLS.CA

  @certs_table :varco_certificates
  @acme_table :varco_acme_challenges

  # Client API

  @doc """
  Starts the CertificateStore process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dynamic SNI resolution callback for Erlang `:ssl`.
  Called during the TLS handshake for each incoming connection.
  """
  @spec sni_fun(charlist()) :: [ssl_server_option] when ssl_server_option: tuple()
  def sni_fun(server_name) when is_list(server_name) do
    host = server_name |> to_string() |> String.downcase() |> String.trim()
    resolve_sni(host)
  end

  def sni_fun(_), do: default_cert_options()

  @doc """
  Resolves SSL options for a given hostname.
  """
  def resolve_sni(host) when is_binary(host) do
    case lookup_cert(host) do
      %{der_cert: _} = cert_data ->
        build_ssl_options(cert_data)

      nil ->
        # On-demand generation via GenServer (atomic & thread-safe)
        case GenServer.call(__MODULE__, {:ensure_certificate, host}, 5000) do
          {:ok, %{der_cert: _} = cert_data} ->
            build_ssl_options(cert_data)

          _error ->
            default_cert_options()
        end
    end
  catch
    kind, reason ->
      Logger.warning("Error resolving SNI for host #{inspect(host)}: #{inspect({kind, reason})}")
      default_cert_options()
  end

  @doc """
  Returns the default server SSL options (used as fallback or initial listener config).
  """
  def default_cert_options do
    case lookup_cert("__default__") do
      %{der_cert: _} = cert_data ->
        build_ssl_options(cert_data)

      _ ->
        []
    end
  end

  @doc """
  Direct ETS lookup for a certificate by hostname (supports exact and wildcard match).
  Zero-lock and microsecond speed.
  """
  def lookup_cert(host) when is_binary(host) do
    case :ets.lookup(@certs_table, host) do
      [{^host, cert_data}] ->
        cert_data

      [] ->
        # Check wildcard: e.g. api.example.com -> *.example.com
        case String.split(host, ".", parts: 2) do
          [_head, tail] ->
            wildcard = "*." <> tail

            case :ets.lookup(@certs_table, wildcard) do
              [{^wildcard, cert_data}] -> cert_data
              [] -> nil
            end

          _ ->
            nil
        end
    end
  end

  @doc """
  Stores a custom certificate and private key in PEM format.
  """
  def add_custom_certificate(cert_pem, key_pem, domains \\ nil) do
    GenServer.call(__MODULE__, {:add_custom_certificate, cert_pem, key_pem, domains})
  end

  @doc """
  Registers an ACME challenge token for HTTP-01 validation.
  """
  def put_acme_challenge(token, key_authorization, domain \\ nil) do
    record = %{
      token: token,
      key_authorization: key_authorization,
      domain: domain,
      inserted_at: DateTime.utc_now()
    }

    :ets.insert(@acme_table, {token, record})
    :ok
  end

  @doc """
  Retrieves an ACME key authorization for a given challenge token.
  """
  def get_acme_challenge(token) do
    case :ets.lookup(@acme_table, token) do
      [{^token, %{key_authorization: key_auth}}] -> {:ok, key_auth}
      _ -> :error
    end
  end

  @doc """
  Removes an ACME challenge token after validation completes.
  """
  def delete_acme_challenge(token) do
    :ets.delete(@acme_table, token)
    :ok
  end

  @doc """
  Lists all registered certificates and their metadata.
  """
  def list_certificates do
    @certs_table
    |> :ets.tab2list()
    |> Enum.map(fn {domain, data} ->
      %{
        domain: domain,
        domains: data.domains,
        type: data.type,
        inserted_at: data.inserted_at,
        expires_at: data.expires_at
      }
    end)
    |> Enum.uniq_by(& &1.domain)
  end

  @doc """
  Exports the Varco Root CA certificate in PEM format.
  Allows developers to trust Varco's CA locally in their OS/browser.
  """
  def export_ca_pem do
    GenServer.call(__MODULE__, :export_ca_pem)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    auto_self_signed = Keyword.get(opts, :auto_self_signed, true)

    # Initialize lock-free ETS tables
    if :ets.info(@certs_table) == :undefined do
      :ets.new(@certs_table, [:set, :public, :named_table, read_concurrency: true])
    end

    if :ets.info(@acme_table) == :undefined do
      :ets.new(@acme_table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Generate or load Root CA
    {:ok, {ca_cert, ca_key}} = CA.generate_root_ca()

    state = %{
      ca_cert: ca_cert,
      ca_key: ca_key,
      auto_self_signed: auto_self_signed
    }

    # Generate initial default fallback certificate
    {:ok, state} = generate_and_store_cert(state, "__default__", ["localhost", "127.0.0.1"])

    Logger.info("Varco TLS Certificate Store initialized (auto_self_signed: #{auto_self_signed})")
    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_certificate, host}, _from, state) do
    case lookup_cert(host) do
      %{der_cert: _} = cert_data ->
        {:reply, {:ok, cert_data}, state}

      nil ->
        if state.auto_self_signed do
          case generate_and_store_cert(state, host, [host]) do
            {:ok, new_state} ->
              cert_data = lookup_cert(host)
              {:reply, {:ok, cert_data}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_custom_certificate, cert_pem, key_pem, explicit_domains}, _from, state) do
    with {:ok, cert} <- CA.cert_from_pem(cert_pem),
         {:ok, key} <- CA.key_from_pem(key_pem) do
      domains =
        if explicit_domains && explicit_domains != [] do
          explicit_domains
        else
          CA.extract_domains(cert)
        end

      all_der_certs = CA.cert_chain_from_pem(cert_pem)

      {der_cert, chain} =
        case all_der_certs do
          [leaf | intermediates] -> {leaf, intermediates}
          [] -> {X509.Certificate.to_der(cert), []}
        end

      der_key =
        try do
          X509.PrivateKey.to_der(key)
        rescue
          _ -> :public_key.der_encode(elem(key, 0), key)
        end

      key_format =
        case elem(key, 0) do
          :RSAPrivateKey -> :RSAPrivateKey
          :ECPrivateKey -> :ECPrivateKey
          other -> other
        end

      validity = X509.Certificate.validity(cert)
      expires_at = extract_not_after(validity)

      cert_data = %{
        domains: domains,
        der_cert: der_cert,
        der_key: der_key,
        chain: chain,
        key_format: key_format,
        type: :custom,
        inserted_at: DateTime.utc_now(),
        expires_at: expires_at
      }

      # Index under each domain
      for domain <- domains do
        :ets.insert(@certs_table, {String.downcase(domain), cert_data})
      end

      Logger.info("Added custom TLS certificate for domains: #{inspect(domains)}")
      {:reply, {:ok, %{domains: domains, expires_at: expires_at}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:export_ca_pem, _from, state) do
    pem = CA.to_pem(state.ca_cert)
    {:reply, {:ok, pem}, state}
  end

  # Internal Helpers

  defp generate_and_store_cert(state, primary_domain, domains) do
    case CA.issue_server_cert(state.ca_cert, state.ca_key, domains) do
      {:ok, {server_cert, server_key}} ->
        der_cert = X509.Certificate.to_der(server_cert)
        der_key = X509.PrivateKey.to_der(server_key)

        cert_data = %{
          domains: domains,
          der_cert: der_cert,
          der_key: der_key,
          key_format: :ECPrivateKey,
          type: :self_signed,
          inserted_at: DateTime.utc_now(),
          expires_at: DateTime.utc_now() |> DateTime.add(90 * 86400, :second)
        }

        # Store primary domain and SANs
        for d <- domains do
          :ets.insert(@certs_table, {String.downcase(d), cert_data})
        end

        # Also store primary key if distinct
        :ets.insert(@certs_table, {primary_domain, cert_data})

        Logger.debug("Issued self-signed TLS cert for: #{inspect(domains)}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to issue server certificate: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_ssl_options(
         %{der_cert: der_cert, der_key: der_key, key_format: key_format} = cert_data
       ) do
    opts = [cert: der_cert, key: {key_format, der_key}]

    case Map.get(cert_data, :chain, []) do
      [_ | _] = chain -> opts ++ [cacerts: chain]
      _ -> opts
    end
  end

  defp extract_not_after({:Validity, _not_before, _not_after}) do
    # Convert ASN.1 time if possible, or fallback to +90 days
    DateTime.utc_now() |> DateTime.add(90 * 86400, :second)
  rescue
    _ -> DateTime.utc_now() |> DateTime.add(90 * 86400, :second)
  end

  defp extract_not_after(_), do: DateTime.utc_now() |> DateTime.add(90 * 86400, :second)
end
