defmodule Varco.TLS.CA do
  @moduledoc """
  Manages Varco's local Certificate Authority (CA) and dynamic TLS certificate issuance.

  Enables zero-touch HTTPS by automatically generating a cryptographic Root CA
  and issuing on-the-fly server certificates for requested hostnames.
  """

  @default_ca_subject "/CN=Varco Development Authority/O=Varco Proxy/C=DE"
  @default_validity_days 3650
  @server_cert_validity_days 90

  @doc """
  Generates a new Root CA key pair and self-signed root certificate.
  """
  @spec generate_root_ca(keyword()) :: {:ok, {X509.Certificate.t(), X509.PrivateKey.t()}}
  def generate_root_ca(opts \\ []) do
    ca_subject = Keyword.get(opts, :subject, @default_ca_subject)
    validity_days = Keyword.get(opts, :validity_days, @default_validity_days)

    ca_key = X509.PrivateKey.new_ec(:secp256r1)

    ca_cert =
      X509.Certificate.self_signed(
        ca_key,
        ca_subject,
        template: :root_ca,
        validity: validity_days
      )

    {:ok, {ca_cert, ca_key}}
  end

  @doc """
  Issues a server certificate for one or more domains, signed by the given CA.
  Returns `{:ok, {server_cert, server_key}}`.
  """
  @spec issue_server_cert(
          X509.Certificate.t(),
          X509.PrivateKey.t(),
          String.t() | [String.t()],
          keyword()
        ) :: {:ok, {X509.Certificate.t(), X509.PrivateKey.t()}}
  def issue_server_cert(ca_cert, ca_key, domains, opts \\ [])

  def issue_server_cert(ca_cert, ca_key, domain, opts) when is_binary(domain) do
    issue_server_cert(ca_cert, ca_key, [domain], opts)
  end

  def issue_server_cert(ca_cert, ca_key, [primary_domain | _] = domains, opts) do
    validity_days = Keyword.get(opts, :validity_days, @server_cert_validity_days)
    server_key = X509.PrivateKey.new_ec(:secp256r1)
    public_key = X509.PublicKey.derive(server_key)

    # Ensure SAN includes all domains
    san_list =
      domains
      |> Enum.flat_map(fn d ->
        # If domain is not an IP or wildcard, also include it cleanly
        [d]
      end)
      |> Enum.uniq()

    extensions = [
      subject_alt_name: X509.Certificate.Extension.subject_alt_name(san_list),
      basic_constraints: X509.Certificate.Extension.basic_constraints(false),
      key_usage: X509.Certificate.Extension.key_usage([:digitalSignature, :keyEncipherment]),
      ext_key_usage: X509.Certificate.Extension.ext_key_usage([:serverAuth, :clientAuth])
    ]

    server_cert =
      X509.Certificate.new(
        public_key,
        "/CN=#{primary_domain}",
        ca_cert,
        ca_key,
        extensions: extensions,
        validity: validity_days
      )

    {:ok, {server_cert, server_key}}
  end

  @doc """
  Converts an X509 Certificate or PrivateKey to PEM string.
  """
  @spec to_pem(X509.Certificate.t() | X509.PrivateKey.t()) :: String.t()
  def to_pem({:OTPCertificate, _, _, _} = cert), do: X509.Certificate.to_pem(cert)
  def to_pem({:Certificate, _, _, _} = cert), do: X509.Certificate.to_pem(cert)
  def to_pem(key), do: X509.PrivateKey.to_pem(key)

  @doc """
  Converts a PEM certificate string into an X509.Certificate struct.
  """
  @spec cert_from_pem(String.t()) :: {:ok, X509.Certificate.t()} | {:error, term()}
  def cert_from_pem(pem_binary) do
    case X509.Certificate.from_pem(pem_binary) do
      {:ok, cert} -> {:ok, cert}
      _ -> {:error, :invalid_pem_certificate}
    end
  end

  @doc """
  Converts a PEM private key string into an X509.PrivateKey struct or Erlang key record.
  Supports PKCS#1 (RSA), SEC1 (EC), and PKCS#8 (unencrypted).
  """
  @spec key_from_pem(String.t()) :: {:ok, term()} | {:error, term()}
  def key_from_pem(pem_binary) when is_binary(pem_binary) do
    case X509.PrivateKey.from_pem(pem_binary) do
      {:ok, key} ->
        {:ok, key}

      _ ->
        case :public_key.pem_decode(pem_binary) do
          [entry | _] ->
            try do
              {:ok, :public_key.pem_entry_decode(entry)}
            rescue
              _ -> {:error, :invalid_pem_key}
            end

          _ ->
            {:error, :invalid_pem_key}
        end
    end
  end

  @doc """
  Extracts all certificate DER binaries from a PEM bundle (leaf + intermediates).
  """
  @spec cert_chain_from_pem(String.t()) :: [binary()]
  def cert_chain_from_pem(pem_binary) when is_binary(pem_binary) do
    case :public_key.pem_decode(pem_binary) do
      entries when is_list(entries) ->
        for {:Certificate, der, _} <- entries, do: der

      _ ->
        []
    end
  end

  @doc """
  Extracts SANs and CN from a certificate struct or DER binary.
  """
  @spec extract_domains(X509.Certificate.t()) :: [String.t()]
  def extract_domains(cert) do
    cn =
      case X509.Certificate.subject(cert) do
        {:rdnSequence, rdn} ->
          # Extract CN from RDN sequence
          Enum.find_value(rdn, fn
            [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}}] -> to_string(cn)
            [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}}] -> to_string(cn)
            _ -> nil
          end)

        _ ->
          nil
      end

    san_domains =
      case X509.Certificate.extension(cert, :subject_alt_name) do
        {:Extension, _, _, dns_names} when is_list(dns_names) ->
          dns_names
          |> Enum.map(fn
            {:dNSName, name} ->
              to_string(name)

            {:iPAddress, ip} ->
              case :inet.ntoa(ip) do
                {:error, _} -> to_string(ip)
                str -> to_string(str)
              end

            other when is_binary(other) ->
              other

            other when is_list(other) ->
              to_string(other)

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    [cn | san_domains] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
