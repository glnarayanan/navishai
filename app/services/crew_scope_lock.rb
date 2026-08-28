class CrewScopeLock
  def self.acquire!(workspace:, scope:)
    raise ArgumentError, "crew scope lock requires an open transaction" unless CrewTask.connection.transaction_open?

    scope = scope.scope_record if scope.respond_to?(:scope_record)
    unless scope.is_a?(SupportCase) || scope.is_a?(Account)
      raise ArgumentError, "crew scope lock requires a case or account"
    end
    value = "crew-work:#{workspace.id}:#{scope.class.base_class.name}:#{scope.id}"
    CrewTask.connection.execute(
      "SELECT pg_advisory_xact_lock(hashtext(#{CrewTask.connection.quote(value)}))"
    )
  end
end
