class PersonalProviderGateway < ProviderConnectionGateway
  def account(action:, workspace_key:, membership_id:, account_key:)
    raise ArgumentError, "invalid personal account operation" unless %w[start status disconnect].include?(action)

    body = JSON.generate(protocol_version: "v1", workspace_key:, membership_id:, account_key:)
    response = signed_provider_post("/v1/personal-accounts/#{action}", body:)
    parse_account(response.body, workspace_key:, membership_id:, account_key:)
  end

  def purge_workspace(workspace_key:)
    response = signed_provider_post("/v1/personal-accounts/purge-workspace", body: JSON.generate(protocol_version: "v1", workspace_key:))
    value = JSON.parse(response.body)
    raise MalformedResponse, "invalid personal account purge" unless value == { "protocol_version" => "v1", "workspace_key" => workspace_key, "purged" => true }

    true
  rescue JSON::ParserError
    raise MalformedResponse, "invalid personal account purge"
  end

  private
    def parse_account(body, workspace_key:, membership_id:, account_key:)
      raise MalformedResponse, "personal account response is too large" if body.bytesize > RunnerProtocol::MAX_BODY_BYTES
      value = JSON.parse(body)
      account = value.fetch("account")
      unless value.keys.sort == %w[account protocol_version] && value["protocol_version"] == "v1" && account.is_a?(Hash) &&
          (account.keys - %w[workspace_key membership_id account_key state installation challenge expires_at runtime_test]).empty? &&
          account.values_at("workspace_key", "membership_id", "account_key") == [ workspace_key, membership_id, account_key ] &&
          PersonalProviderAccount::STATES.include?(account["state"])
        raise MalformedResponse, "personal account identity is invalid"
      end
      account["expires_at"] = Time.iso8601(account.fetch("expires_at")) if account["expires_at"].present?
      validate_challenge!(account.fetch("challenge")) if account["challenge"]
      if account["state"] == "connected"
        report = account.fetch("installation")
        RunnerProtocol::RuntimeDetectionResponse.new("protocol_version" => "v2", "installations" => [ report ])
        unless report["execution_mode"] == "strong_isolated" && report["adapter_key"] == "codex_subscription"
          raise MalformedResponse, "personal execution boundary is invalid"
        end
        test = account.fetch("runtime_test").merge(
          "protocol_version" => "v1", "workspace_key" => workspace_key, "request_id" => account_key,
          "detection_key" => report.fetch("detection_key")
        )
        test["failure_code"] = nil if test["failure_code"] == ""
        RunnerProtocol::RuntimeTestResponse.new(test, workspace_key:, request_id: account_key,
          detection_key: report.fetch("detection_key"), execution_mode: "strong_isolated",
          configuration_fingerprint: report.fetch("configuration_fingerprint"))
        raise MalformedResponse, "personal account test did not pass" unless test["status"] == "passed"
        account["runtime_test"] = test
      elsif account["installation"] || account["runtime_test"]
        raise MalformedResponse, "inactive personal account contains runtime credentials"
      end
      account
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError, RunnerProtocol::MalformedMessage
      raise MalformedResponse, "personal account response is invalid"
    end

    def validate_challenge!(challenge)
      unless challenge.is_a?(Hash) && challenge.keys.sort == %w[login_id user_code verification_url] &&
          challenge["login_id"].is_a?(String) && challenge["login_id"].bytesize.between?(1, 128) &&
          challenge["verification_url"] == "https://auth.openai.com/codex/device" &&
          challenge["user_code"].is_a?(String) && challenge["user_code"].match?(/\A[A-Za-z0-9-]{4,64}\z/)
        raise MalformedResponse, "personal account challenge is invalid"
      end
    end
end
