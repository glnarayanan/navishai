class CustomerIdentityGraph
  def self.lock!(workspace)
    value = SourceIdentity.connection.quote(lock_name(workspace))
    SourceIdentity.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{value}))")
  end

  def self.lock_name(workspace)
    "customer-identity-graph:#{workspace.id}"
  end
  private_class_method :lock_name
end
