module SecurityRateLimits
  AUTHENTICATION = { to: 10, within: 3.minutes, scope: :authentication }.freeze
  SENSITIVE = { to: 5, within: 10.minutes, scope: :sensitive }.freeze
end
