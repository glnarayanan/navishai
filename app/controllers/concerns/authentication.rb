module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.active.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.fullpath if request.get? || request.head?
      redirect_to new_session_path
    end

    def start_new_session_for(user)
      user.with_lock do
        return_to = session.delete(:return_to_after_authenticating)
        reset_session
        duration = user.break_glass? ? 15.minutes : 12.hours
        new_session = user.sessions.create!(
          user_agent: request.user_agent,
          ip_address: request.remote_ip,
          authentication_method: user.break_glass? ? :break_glass : :local,
          expires_at: duration.from_now
        )
        Current.session = new_session
        cookies.signed[:session_id] = {
          value: new_session.id,
          expires: new_session.expires_at,
          httponly: true,
          secure: Rails.env.production?,
          same_site: :lax
        }
        return_to || root_path
      end
    end

    def terminate_session
      Current.session&.revoke!
      Current.session = nil
      cookies.delete(:session_id)
    end
end
