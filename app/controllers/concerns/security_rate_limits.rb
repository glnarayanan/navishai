module SecurityRateLimits
  AUTHENTICATION = { to: 10, within: 3.minutes }.freeze
  SENSITIVE = { to: 5, within: 10.minutes }.freeze
end
