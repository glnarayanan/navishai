class SystemMailUnavailableDelivery
  def initialize(*) = nil

  def deliver!(_mail)
    raise "System mail is unavailable; configure NAVISHAI_SYSTEM_SMTP_* deployment settings"
  end
end
