defmodule Varco.TLS.ACME do
  @moduledoc """
  Manages Automated Certificate Management Environment (ACME / Let's Encrypt) operations.

  Coordinates HTTP-01 challenges, certificate renewals, and cluster-wide challenge distribution.
  """

  require Logger
  alias Varco.TLS.CertificateStore

  @doc """
  Registers an incoming ACME challenge token and its authorization response.
  When the ACME server contacts Varco via `/.well-known/acme-challenge/:token`,
  this token will be served immediately.
  """
  def register_challenge(token, key_authorization, domain \\ nil) do
    Logger.info("Registered ACME HTTP-01 challenge for #{domain || "token"} (token: #{token})")
    CertificateStore.put_acme_challenge(token, key_authorization, domain)
  end

  @doc """
  Resolves a challenge token for HTTP-01 validation.
  """
  def get_challenge_response(token) do
    CertificateStore.get_acme_challenge(token)
  end

  @doc """
  Cleans up completed challenge tokens.
  """
  def complete_challenge(token) do
    CertificateStore.delete_acme_challenge(token)
  end
end
