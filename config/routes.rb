Rails.application.routes.draw do
  root "pages#show"
  resources :workspaces, only: %i[index show new create edit update] do
    resources :workspace_invitations, only: %i[index create destroy]
    resources :corpora, only: %i[index create show] do
      resources :sources, only: %i[create show destroy]
      resources :corpus_analyses, only: %i[create show update]
      resources :graders, only: %i[index create show update]
      resources :eval_cases, only: %i[new create show]
      resources :eval_suites, only: %i[index create show update]
      resources :evaluation_targets, only: %i[index create show update]
      resources :evaluation_runs, only: %i[index create show update]
      resources :evaluation_results, only: :show do
        post :regression, on: :member
      end
      resources :calibration_sets, only: %i[index create show] do
        resources :calibration_samples, only: %i[new create show] do
          post :label, on: :member
          post :judge, on: :member
          post :interrupt_judge, on: :member
        end
      end
      resources :scenarios, only: %i[index create show update] do
        post :review, on: :member
        post :variant, on: :member
      end
    end
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
