Rails.application.routes.draw do
  root "pages#show"
  resources :workspaces, only: %i[index show new create edit update] do
    resources :workspace_invitations, only: %i[index create destroy]
  end
  get "invitations", to: "workspace_invitation_acceptances#show", as: :workspace_invitation_acceptance
  post "invitations", to: "workspace_invitation_acceptances#create"
  get "setup", to: "setups#new"
  resource :setup, only: %i[new create]
  resource :break_glass_session, only: %i[new create], path: "break-glass/session"
  get "verification", to: "verifications#show", as: :verification
  patch "verification", to: "verifications#update"
  resource :session, only: %i[new create destroy]
  post "session/oidc", to: "oidc_sessions#create", as: :oidc_session
  get "session/oidc/callback", to: "oidc_sessions#callback", as: :oidc_session_callback
  resources :passwords, only: %i[new create]
  get "passwords/edit", to: "passwords#edit", as: :edit_password
  put "passwords", to: "passwords#update", as: :password
  get "up" => "rails/health#show", as: :rails_health_check
end
