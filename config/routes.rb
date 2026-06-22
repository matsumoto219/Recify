Rails.application.routes.draw do
  post "/rails/active_storage/direct_uploads", to: "errors#not_found"

  namespace :admin do
    root "dashboard#show"
    get "external_services/status", to: "external_services#status", as: :external_services_status
    resource :system_operations, only: %i[show]
    get "system_settings", to: "system_settings#index", as: :system_settings
    get "system_settings/:key",
        to: "system_settings#show",
        as: :system_setting,
        constraints: { key: /[^\/]+/ }
    patch "system_settings/:key",
          to: "system_settings#update",
          constraints: { key: /[^\/]+/ }
    resources :audit_logs, only: %i[index show]
    resources :security_events, only: %i[index show] do
      patch :resolve, on: :member
      patch :ignore, on: :member
      post "ip_access/manual_block", to: "security_events#manual_ip_block", as: :manual_ip_block, on: :member
      post "ip_access/manual_unblock", to: "security_events#manual_ip_unblock", as: :manual_ip_unblock, on: :member
      post "ip_access/rack_attack_ban_reset", to: "security_events#rack_attack_ban_reset", as: :rack_attack_ban_reset, on: :member
    end
    resources :announcements, only: %i[index show new create edit update] do
      patch :publish, on: :member
      patch :archive, on: :member
    end
    resources :contact_requests, only: %i[index show update]
    resources :users, only: %i[index show] do
      post "operations/lock", to: "user_operations#lock", as: :lock_operation, on: :member
      post "operations/unlock", to: "user_operations#unlock", as: :unlock_operation, on: :member
      post "operations/force_passkey_reset", to: "user_operations#force_passkey_reset", as: :force_passkey_reset_operation, on: :member
      post "operations/force_two_factor_reset", to: "user_operations#force_two_factor_reset", as: :force_two_factor_reset_operation, on: :member
      post "operations/force_password_reset_instruction", to: "user_operations#force_password_reset_instruction", as: :force_password_reset_instruction_operation, on: :member
      post "operations/admin_email_change_recovery", to: "user_operations#admin_email_change_recovery", as: :admin_email_change_recovery_operation, on: :member
      post "operations/revoke_sessions", to: "user_operations#revoke_sessions", as: :revoke_sessions_operation, on: :member
      post "operations/delete", to: "user_operations#delete", as: :delete_operation, on: :member
      post "limit_overrides", to: "user_limit_overrides#create", as: :limit_overrides, on: :member
    end
    get "receipt_analysis_cleanup", to: "receipt_analysis_cleanup#show"
    post "receipt_analysis_cleanup/stale", to: "receipt_analysis_cleanup#execute_stale", as: :receipt_analysis_cleanup_stale
    post "receipt_analysis_cleanup/retention", to: "receipt_analysis_cleanup#execute_retention", as: :receipt_analysis_cleanup_retention
    resource :passkey_reauthentication, only: %i[new create], path: "reauth/passkey" do
      post :options
    end
    resources :receipt_analysis_runs, only: %i[index show], param: :run_key do
      post :retry, on: :member
    end
  end

  if Rails.env.development? && defined?(LetterOpenerWeb::Engine)
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  devise_for :users, controllers: {
    sessions: "users/sessions",
    registrations: "users/registrations",
    passwords: "users/passwords",
    confirmations: "users/confirmations",
    unlocks: "users/unlocks"
  }
  post "/users/passkey_sessions/options", to: "users/passkey_sessions#options", as: :users_passkey_sessions_options
  post "/users/passkey_sessions", to: "users/passkey_sessions#create", as: :users_passkey_sessions
  get "/users/two_factor/passkey", to: "users/two_factor/passkeys#new", as: :users_two_factor_passkey
  post "/users/two_factor/passkey/options", to: "users/two_factor/passkeys#options", as: :users_two_factor_passkey_options
  post "/users/two_factor/passkey", to: "users/two_factor/passkeys#create", as: :users_two_factor_passkey_create
  get "/users/two_factor/totp", to: "users/two_factor/totps#new", as: :users_two_factor_totp
  post "/users/two_factor/totp", to: "users/two_factor/totps#create", as: :users_two_factor_totp_create
  get "/users/two_factor/recovery_code", to: "users/two_factor/recovery_codes#new", as: :users_two_factor_recovery_code
  post "/users/two_factor/recovery_code", to: "users/two_factor/recovery_codes#create", as: :users_two_factor_recovery_code_create
  post "/users/guest_sign_in", to: "guest_sessions#create", as: :guest_sign_in
  get "/contact", to: "contact_requests#new", as: :contact
  post "/contact", to: "contact_requests#create"
  resource :legal_consent, only: %i[show create], path: "legal/consent"
  get "/terms", to: "legal#terms", as: :terms
  get "/terms/versions", to: "legal#terms_versions", as: :terms_versions
  get "/terms/versions/:version",
      to: "legal#terms_version",
      as: :terms_version,
      constraints: { version: /\d{4}-\d{2}-\d{2}/ }
  get "/privacy", to: "legal#privacy", as: :privacy
  get "/privacy/versions", to: "legal#privacy_versions", as: :privacy_versions
  get "/privacy/versions/:version",
      to: "legal#privacy_version",
      as: :privacy_version,
      constraints: { version: /\d{4}-\d{2}-\d{2}/ }
  get "/sitemap.xml", to: "sitemap#show", defaults: { format: :xml }, as: :sitemap
  resources :announcements, only: %i[index show], param: :public_id
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  get "/404", to: "errors#not_found"
  get "/403", to: "errors#forbidden"
  get "/422", to: "errors#unprocessable"
  get "/503", to: "errors#service_unavailable"
  get "/500", to: "errors#internal_server_error"
  get "/errors/forbidden", to: "errors#forbidden"
  get "/errors/not_found", to: "errors#not_found"
  get "/errors/unprocessable", to: "errors#unprocessable"
  get "/errors/service_unavailable", to: "errors#service_unavailable"
  get "/errors/internal_server_error", to: "errors#internal_server_error"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
  root "home#index"

  # Receiptsコントローラ
  resources :receipts, param: :public_id do
    collection do
      get :select_input_method
      get :new_upload
      post :upload
    end
  end

  resources :notifications, only: [ :index, :destroy ], param: :uid do
    member do
      patch :read
    end

    collection do
      patch :read_all
    end
  end

  get "/external_services/status", to: "external_services#status", as: :external_services_status

  if Rails.env.development? || Rails.env.test?
    namespace :debug do
      post "/external_services/:service/:state", to: "external_services#update", as: :external_service_state
    end
  end

  # アカウント設定
  get "/settings", to: "settings#index", as: :settings
  get "/settings/account", to: "settings#account", as: :settings_account
  get "/settings/security", to: "settings#security", as: :settings_security
  post "/settings/passkeys/options", to: "users/passkeys#options", as: :settings_passkeys_options
  post "/settings/passkeys", to: "users/passkeys#create", as: :settings_passkeys
  delete "/settings/passkeys/:uid", to: "users/passkeys#destroy", as: :settings_passkey
  get "/settings/security/totp/new", to: "users/two_factor/totp_settings#new", as: :new_settings_security_totp
  post "/settings/security/totp", to: "users/two_factor/totp_settings#create", as: :settings_security_totp
  delete "/settings/security/totp", to: "users/two_factor/totp_settings#destroy"
  post "/settings/security/recovery_codes/regenerate",
       to: "users/two_factor/recovery_codes#regenerate",
       as: :settings_security_recovery_codes_regenerate
  patch "settings", to: "settings#update"
end
