class NotificationMailer < ApplicationMailer
  def alert(notification)
    @notification = notification
    @workspace = notification.workspace
    @destination = "#{root_url.delete_suffix("/")}#{notification.path}"
    mail subject: "#{notification.title} · #{@workspace.name}", to: notification.recipient_membership.user.email_address
  end
end
