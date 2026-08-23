Rails.application.routes.draw do
  root "workspaces#index"
  resources :workspaces, only: %i[ index show ] do
    resources :workspace_invitations, only: %i[ index create destroy ]
    resources :support_cases, path: "cases", only: %i[ index show ] do
      member do
        patch :transition, controller: "support_case_commands"
        patch :assignment, controller: "support_case_commands"
        patch :priority, controller: "support_case_commands"
        post :tag, controller: "support_case_commands"
        delete "tags/:tag_id", action: :untag, as: :tagging, controller: "support_case_commands"
        post :notes, action: :add_note, controller: "support_case_commands"
        post "tag-definitions", action: :create_tag, as: :create_tag, controller: "support_case_commands"
      end
    end
  end
  get "invitations", to: "workspace_invitation_acceptances#show", as: :workspace_invitation_acceptance
  post "invitations", to: "workspace_invitation_acceptances#create"
  resource :setup, only: %i[ new create ]
  resource :break_glass_session, only: %i[ new create ], path: "break-glass/session"
  get "verification", to: "verifications#show", as: :verification
  patch "verification", to: "verifications#update"
  resource :session, only: %i[ new create destroy ]
  resources :passwords, only: %i[ new create ]
  get "passwords/edit", to: "passwords#edit", as: :edit_password
  put "passwords", to: "passwords#update", as: :password
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
