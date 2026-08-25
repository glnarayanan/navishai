Rails.application.routes.draw do
  namespace :webhooks do
    post "shared-email/:webhook_key", to: "shared_email#create", as: :shared_email
    post "runner-events", to: "runner_events#create", as: :runner_events
  end
  root "workspaces#index"
  resources :workspaces, only: %i[ index show ] do
    resources :workspace_invitations, only: %i[ index create destroy ]
    resources :shared_email_inboxes, path: "email-inboxes", only: %i[ index create update ] do
      post :reconcile, on: :member
    end
    resources :attachments, only: :show, controller: "attachment_downloads"
    resources :knowledge_sources, path: "knowledge", only: %i[ index show create update destroy ]
    resources :memory_records, path: "memory", only: %i[ index show destroy ] do
      post :corrections, controller: "memory_corrections", action: :create
      post "corrections/:correction_id/review", controller: "memory_corrections", action: :review,
        as: :correction_review
      post :retry_removal, on: :member
    end
    resources :crew_templates, path: "crews", only: :index do
      resources :agent_profiles, only: :update
    end
    resources :runtime_installations, path: "runtimes", only: %i[ index update ] do
      post :detect, on: :collection
    end
    resources :support_cases, path: "cases", only: %i[ index show ] do
      resources :crew_tasks, path: "crew-work", only: %i[ index show create ] do
        post :command, on: :member
        resources :public_web_searches, path: "public-web-searches", only: :create
        resources :public_web_search_results, path: "public-web-results", only: [] do
          resources :public_web_extractions, path: "extractions", only: :create
        end
        resources :execution_runs, path: "runs", only: %i[ index create ] do
          post :reconcile, on: :member
        end
      end
      member do
        patch :transition, controller: "support_case_commands"
        patch :assignment, controller: "support_case_commands"
        patch :priority, controller: "support_case_commands"
        post :tag, controller: "support_case_commands"
        delete "tags/:tag_id", action: :untag, as: :tagging, controller: "support_case_commands"
        post :notes, action: :add_note, controller: "support_case_commands"
        post "tag-definitions", action: :create_tag, as: :create_tag, controller: "support_case_commands"
        post :email_draft, controller: "email_replies", action: :save_draft
        post :email_send, controller: "email_replies", action: :send_email
        post "email_deliveries/:delivery_id/review", controller: "email_replies", action: :review_delivery,
          as: :email_delivery_review
        post :email_attachments, controller: "email_attachments", action: :create
        delete "email_attachments/:attachment_id", controller: "email_attachments", action: :destroy,
          as: :email_attachment
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
