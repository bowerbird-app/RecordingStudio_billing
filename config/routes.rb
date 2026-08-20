# frozen_string_literal: true

RecordingStudioBilling::Engine.routes.draw do
  root "billing#index"

  post "admin/operations/:operation", to: "admin_operations#perform", as: :admin_operations_create
  post "admin/operations/:operation/:id", to: "admin_operations#perform", as: :admin_operation

  resource :billing, only: :show, controller: "billing" do
    get :plan
    get :plan_requests
    get :addons
    get :usage
    get :invoices
    get :payments
    get :settings
    patch :update_settings
    post :checkout, controller: "checkout_selections", action: :create
    post :portal, controller: "portals"
  end

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
