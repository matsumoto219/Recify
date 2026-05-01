Rails.application.routes.draw do
  devise_for :users, controllers: {
    sessions: "users/sessions",
    registrations: "users/registrations",
    passwords: "users/passwords"
  }
  post "/users/guest_sign_in", to: "guest_sessions#create", as: :guest_sign_in
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
  root "home#index"

  # Receiptsコントローラ
  resources :receipts do
    collection do
      get :select_input_method
      get :new_upload
      post :upload
    end
  end

  # アカウント設定
  get "/settings", to: "settings#index", as: :settings
  get "/settings/account", to: "settings#account", as: :settings_account
  get "/settings/security", to: "settings#security", as: :settings_security
  patch "settings", to: "settings#update"
end
