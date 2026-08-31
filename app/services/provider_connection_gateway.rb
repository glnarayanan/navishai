class ProviderConnectionGateway < RunnerClient
  def catalog(workspace_key:)
    body = JSON.generate(protocol_version: ProviderConnectionProtocol::VERSION, workspace_key:)
    response = signed_provider_post(ProviderConnectionProtocol::CATALOG_PATH, body:, timeout_error: Unavailable)
    ProviderConnectionProtocol.parse_catalog(response.body, workspace_key:)
  rescue ProviderConnectionProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  def models(workspace_key:, adapter_key:)
    body = JSON.generate(
      protocol_version: ProviderConnectionProtocol::VERSION, workspace_key:, adapter_key:
    )
    response = signed_provider_post(
      ProviderConnectionProtocol::MODELS_PATH, body:, read_timeout: 20, timeout_error: Unavailable
    )
    ProviderConnectionProtocol.parse_models(response.body, workspace_key:, adapter_key:)
  rescue ProviderConnectionProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  def configure(workspace_key:, request_id:, adapter_key:, auth_mode:, model:, api_key:)
    body = JSON.generate(
      protocol_version: ProviderConnectionProtocol::VERSION, workspace_key:, request_id:, adapter_key:,
      auth_mode:, model:, api_key:
    )
    response = signed_provider_post(ProviderConnectionProtocol::CONFIGURE_PATH, body:, read_timeout: 55)
    ProviderConnectionProtocol.parse_provider(response.body, workspace_key:)
  rescue ProviderConnectionProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  def remove(workspace_key:, request_id:, adapter_key:)
    body = JSON.generate(
      protocol_version: ProviderConnectionProtocol::VERSION, workspace_key:, request_id:, adapter_key:
    )
    response = signed_provider_post(ProviderConnectionProtocol::REMOVE_PATH, body:)
    ProviderConnectionProtocol.parse_provider(response.body, workspace_key:)
  rescue ProviderConnectionProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  def purge_workspace(workspace_key:)
    body = JSON.generate(
      protocol_version: ProviderConnectionProtocol::VERSION,
      workspace_key:, request_id: SecureRandom.uuid
    )
    response = signed_provider_post(ProviderConnectionProtocol::PURGE_WORKSPACE_PATH, body:)
    ProviderConnectionProtocol.parse_workspace_purge(response.body, workspace_key:)
  rescue ProviderConnectionProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  private
    def signed_provider_post(path, body:, read_timeout: 10, timeout_error: AmbiguousResult)
      timestamp = @clock.call.to_i.to_s
      request = Net::HTTP::Post.new(path)
      request["Content-Type"] = "application/json"
      request["X-NavishAI-Timestamp"] = timestamp
      request["X-NavishAI-Signature"] = RunnerProtocol.signature(
        secret: @secret, timestamp:, method: "POST", path:, body:
      )
      request.body = body
      response = perform(request, read_timeout:)
      raise_for_response(response) unless response.code == 200

      response
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
      raise timeout_error, "provider request outcome is unknown: #{error.class}"
    rescue OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
      raise Unavailable, "runner is unavailable: #{error.class}"
    end
end
