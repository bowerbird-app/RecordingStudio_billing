# frozen_string_literal: true

RecordingStudioBilling::Engine.routes.draw do
  root "billing#index"

  get "admin/products/new", to: "admin_products#new", as: :new_admin_product
  post "admin/operations/:operation", to: "admin_operations#perform", as: :admin_operations_create
  post "admin/operations/:operation/:id", to: "admin_operations#perform", as: :admin_operation

  get "plan", to: "billing#plan", as: :plan_billing
  get "plan_requests", to: "billing#plan_requests", as: :plan_requests_billing
  get "addons", to: "billing#addons", as: :addons_billing
  get "usage", to: "billing#usage", as: :usage_billing
  get "invoices", to: "billing#invoices", as: :invoices_billing
  get "payments", to: "billing#payments", as: :payments_billing
  get "settings", to: "billing#settings", as: :settings_billing
  patch "settings", to: "billing#update_settings", as: :update_settings_billing
  get "checkout/new", to: "checkout_selections#new", as: :new_checkout_billing
  post "checkout", to: "checkout_selections#create", as: :checkout_billing
  post "portal", to: "portals#portal", as: :portal_billing

  resources :subscriptions, only: [] do
    get :cancel_confirmation, on: :member
    post :cancel, on: :member
    get :resume_confirmation, on: :member
    post :resume, on: :member
    get :change_selection, on: :member
    post :compare_change, on: :member
    post :confirm_change, on: :member
  end

  resources :subscription_changes, only: :show, controller: "subscription_change_results"

  resources :checkout, only: %i[show] do
    get :return, on: :member, action: :return
  end

  resources :invoices, only: %i[show] do
    get :download, on: :member
  end
end
