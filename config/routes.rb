Rails.application.routes.draw do
  get "oauth/:provider/callback", to: "workspace_connectors#oauth_return", as: :integration_oauth_callback
  namespace :webhooks do
    post "shared-email/:webhook_key", to: "shared_email#create", as: :shared_email
    post "intercom/:webhook_key", to: "intercom#create", as: :intercom
    post "runner-events", to: "runner_events#create", as: :runner_events
  end
  root "pages#show"
  resources :workspaces, only: %i[ index show new create edit update ] do
    resource :deletion, only: %i[ create update ], controller: "workspace_deletions"
    resource :data_controls, only: %i[ show update ], controller: "workspace_data_controls" do
      post :expire
      post :expire_audit
      get :export
      post :import
      post :verify_archive
    end
    resources :notifications, only: %i[ index update ] do
      post :read_all, on: :collection
    end
    resource :setup_checklist, only: :show, controller: "workspace_setup_checklists" do
      post :scanner_check
      post :memory_check
    end
    resources :outbound_webhook_endpoints, path: "webhooks", only: %i[ index create update ]
    resources :workspace_invitations, only: %i[ index create destroy ]
    resources :shared_email_inboxes, path: "email-inboxes", only: %i[ index create update ] do
      post :reconcile, on: :member
    end
    resource :search_settings, controller: "workspace_search_settings", only: %i[edit update]
    resources :notion_knowledge_connections, only: %i[create update] do
      post :sync, on: :member
    end
    resources :personal_provider_accounts, only: %i[index create show destroy] do
      post :refresh, on: :member
    end
    resources :products, only: %i[index create update]
    resources :workspace_connectors, path: "connectors", param: :provider, only: %i[index update] do
      member do
        post :connect
        get :callback
        get :content
        delete :disconnect
      end
    end
    resources :intercom_connections, path: "intercom", only: %i[ index create update ] do
      resource :knowledge_applicability, only: %i[update destroy], controller: "knowledge_applicabilities"
      member do
        patch :help_center
        post :sync_help_center
      end
      post :reconcile, on: :member
      post :backfill_preview, on: :member
      post "backfill/:manifest_id/confirm", action: :backfill_confirm, on: :member, as: :backfill_confirm
      post "backfill-runs/:run_id/resume", action: :backfill_resume, on: :member, as: :backfill_resume
      post "backfill-exceptions/:exception_id/resolve-identity", action: :backfill_resolve_identity,
        on: :member, as: :backfill_resolve_identity
    end
    resources :attachments, only: :show, controller: "attachment_downloads"
    resources :knowledge_sources, path: "knowledge", only: %i[ index show create update destroy ] do
      resource :knowledge_applicability, only: %i[update destroy], controller: "knowledge_applicabilities"
    end
    resources :memory_records, path: "memory", only: %i[ index show destroy ] do
      get :export, on: :collection
      post :import, on: :collection
      post :reconstruct, on: :collection
      post :corrections, controller: "memory_corrections", action: :create
      post "corrections/:correction_id/review", controller: "memory_corrections", action: :review,
        as: :correction_review
      post :retry_removal, on: :member
    end
    resources :crew_templates, path: "crews", only: :index do
      resources :agent_profiles, only: :update
    end
    resources :resolution_contracts, path: "resolution-contracts", only: :update
    resource :governed_policy, path: "policies", only: :show, controller: "governed_policies" do
      post :propose
      post "proposals/:proposal_id/preview", action: :preview, as: :preview
      post "proposals/:proposal_id/publish", action: :publish, as: :publish
      post "publications/:publication_id/rollback", action: :rollback, as: :rollback
    end
    resources :runtime_installations, path: "runtimes", only: %i[ index update ] do
      post :detect, on: :collection
      post :test, on: :member
    end
    resources :provider_connections, path: "provider-connections", param: :adapter_key,
      only: %i[ new create edit update destroy ] do
      post :models, on: :collection
    end
    resource :usage_rates, path: "usage-rates", only: %i[ show create ], controller: "usage_rates" do
      post :rollback
    end
    resource :reliability_cockpit, path: "reliability", only: :show, controller: "reliability_cockpits" do
      post "runs/:run_id/reconcile", action: :reconcile_run, as: :reconcile_run
      post "runs/:run_id/retry", action: :retry_run, as: :retry_run
      post :reconstruct_memory
    end
    get "explain/:subject_type/:subject_id", to: "outcome_explanations#show",
      as: :outcome_explanation, constraints: { subject_type: /case|account|run|health-assessment/ }
    resource :health_scorecard, path: "scorecard", only: :show do
      post :propose
      post :generate
      post :accept
      post :backtest
      post :publish
      post :rollback
    end
    resources :accounts, only: %i[ index show ] do
      post :recalculate, on: :member
      post :request_risk_review, on: :member
      resources :interventions, only: :create, controller: "customer_success_interventions" do
        member do
          post :approve
          post :complete
          post :abandon
          post :review
        end
      end
      get "health-evidence/:assessment_id/:signal_key", to: "health_evidence#show", on: :member,
        as: :health_evidence
      post "risk-reviews/:investigation_id/start", action: :start_risk_review, on: :member,
        as: :start_risk_review
      post "risk-reviews/:investigation_id/resolve", action: :resolve_risk_review, on: :member,
        as: :resolve_risk_review
      post "identity-reviews/:source_identity_id", action: :resolve_identity, on: :member,
        as: :resolve_identity
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
    end
    post "account-imports", to: "account_imports#create", as: :account_imports
    post "account-api-inputs", to: "account_imports#create_api", as: :account_api_inputs
    resources :support_cases, path: "cases", only: %i[ index show ] do
      resource :product_mapping, only: :update, controller: "support_case_products"
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
        post :intercom_draft, controller: "intercom_replies", action: :save_draft
        post :intercom_send, controller: "intercom_replies", action: :send_reply
        post "intercom_deliveries/:delivery_id/review", controller: "intercom_replies", action: :review_delivery,
          as: :intercom_delivery_review
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
  post "session/oidc", to: "oidc_sessions#create", as: :oidc_session
  get "session/oidc/callback", to: "oidc_sessions#callback", as: :oidc_session_callback
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
