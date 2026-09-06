# Selects the deployment's malware-scan adapter at boot so a misconfigured
# NAVISHAI_ATTACHMENT_SCANNER value fails visibly instead of quarantining every
# attachment forever. Tests keep the fail-closed default and pass scanners explicitly.
Rails.application.config.to_prepare do
  AttachmentScanner.default = AttachmentScanner.from_environment unless Rails.env.test?
end
