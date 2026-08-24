class NotificationsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def index
    @membership = Current.require_membership!
    @notifications = @membership.notifications.newest_first.limit(100)
  end

  def update
    notification = Current.require_membership!.notifications.find(params[:id])
    notification.update!(read_at: notification.read_at || Time.current)
    redirect_to notification.path
  end

  def read_all
    Current.require_membership!.notifications.unread.update_all(read_at: Time.current, updated_at: Time.current)
    redirect_to workspace_notifications_path(Current.workspace), notice: "Notifications marked as read."
  end
end
