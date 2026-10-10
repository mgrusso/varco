defmodule Varco.TLSTest do
  use ExUnit.Case, async: false
  alias Varco.TLS.{CA, CertificateStore, ACME}

  setup do
    # Ensure CertificateStore is running
    case Process.whereis(CertificateStore) do
      nil -> start_supervised!({CertificateStore, auto_self_signed: true})
      _ -> :ok
    end

    :ok
  end

  test "generates root CA and issues server certificate" do
    {:ok, {ca_cert, ca_key}} = CA.generate_root_ca()
    assert match?({:OTPCertificate, _, _, _}, ca_cert)
    assert match?({:ECPrivateKey, _, _, _, _, _}, ca_key)

    pem = CA.to_pem(ca_cert)
    assert String.starts_with?(pem, "-----BEGIN CERTIFICATE-----")

    {:ok, {srv_cert, srv_key}} = CA.issue_server_cert(ca_cert, ca_key, ["app.test", "*.app.test"])
    assert match?({:OTPCertificate, _, _, _}, srv_cert)
    assert match?({:ECPrivateKey, _, _, _, _, _}, srv_key)

    domains = CA.extract_domains(srv_cert)
    assert "app.test" in domains
  end

  test "dynamic SNI resolves and generates certificates automatically" do
    # When requesting an unknown domain with auto_self_signed enabled
    ssl_opts = CertificateStore.sni_fun(~c"zero-config.example.com")
    assert Keyword.has_key?(ssl_opts, :cert)
    assert Keyword.has_key?(ssl_opts, :key)

    {key_type, der_key} = Keyword.get(ssl_opts, :key)
    assert key_type == :ECPrivateKey
    assert is_binary(der_key)
    assert is_binary(Keyword.get(ssl_opts, :cert))

    # Second lookup is instant from ETS
    cached = CertificateStore.lookup_cert("zero-config.example.com")
    assert cached != nil
    assert "zero-config.example.com" in cached.domains
  end

  test "supports custom certificate upload and wildcard matching" do
    {:ok, {ca_cert, ca_key}} = CA.generate_root_ca()
    {:ok, {srv_cert, srv_key}} = CA.issue_server_cert(ca_cert, ca_key, ["*.custom.internal"])

    cert_pem = CA.to_pem(srv_cert)
    key_pem = CA.to_pem(srv_key)

    {:ok, meta} = CertificateStore.add_custom_certificate(cert_pem, key_pem)
    assert "*.custom.internal" in meta.domains

    # Exact wildcard resolution
    opts = CertificateStore.sni_fun(~c"api.custom.internal")
    assert Keyword.has_key?(opts, :cert)

    certs = CertificateStore.list_certificates()
    assert Enum.any?(certs, fn c -> "*.custom.internal" in c.domains end)
  end

  test "manages ACME challenges" do
    token = "test-token-123"
    auth = "test-token-123.some_account_thumbprint"

    ACME.register_challenge(token, auth, "acme.example.com")
    assert ACME.get_challenge_response(token) == {:ok, auth}

    ACME.complete_challenge(token)
    assert ACME.get_challenge_response(token) == :error
  end
end
