# frozen_string_literal: true

module RecordingStudioBilling
  class AdminOperationsController < ApplicationController
    include RecordingStudioAdmin::AdminActionAuditing

    COMMERCIAL_RESOURCES = {
      "provider_account" => ["billing_provider_accounts", ProviderAccount],
      "market" => ["billing_markets", Market],
      "product" => ["billing_products", Product],
      "billing_option" => ["billing_options", BillingOption],
      "price" => ["billing_prices", Price],
      "overage_price" => ["billing_overage_prices", OveragePrice],
      "feature" => ["billing_features", Feature],
      "product_rule" => ["billing_product_rules", ProductRule],
      "usage_unit" => ["billing_usage_units", UsageUnit],
      "meter" => ["billing_meters", Meter],
      "rate_card" => ["billing_rate_cards", RateCard],
      "rate" => ["billing_rates", Rate],
      "cost_card" => ["billing_cost_cards", CostCard],
      "cost_rate" => ["billing_cost_rates", CostRate]
    }.freeze

    skip_before_action :load_root_recording!
    before_action :load_operation!
    before_action :load_admin_context!
    before_action :authorize_operation!

    def perform
      perform_recording_studio_admin_action!(resource_key, action_key, operation_audit_record) do
        dispatch_operation!
      end
      redirect_to recording_studio_admin_context.admin_screen_path(resource_key), notice: "Billing operation completed."
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to recording_studio_admin_context.admin_screen_path(resource_key), alert: e.message
    end

    private

    def load_operation!
      return load_commercial_operation! if commercial_operation?
      return load_feature_override_operation! if feature_override_operation?

      @operation_record, @resource_key, @action_key = case params[:operation]
                                                      when "publish_price"
                                                        [Price.with_current_recording.find(params[:id]),
                                                         "billing_prices", :publish]
                                                      when "preview_plan_update"
                                                        [PlanUpdate.with_current_recording.find(params[:id]),
                                                         "billing_plan_updates", :preview]
                                                      when "confirm_plan_update"
                                                        [PlanUpdateRun.find(params[:id]), "billing_plan_update_runs",
                                                         :confirm]
                                                      when "apply_plan_update"
                                                        [PlanUpdateRun.find(params[:id]), "billing_plan_update_runs",
                                                         :apply]
                                                      when "reconcile_command"
                                                        [FinancialCommand.find(params[:id]),
                                                         "billing_financial_commands", :reconcile]
                                                      when "create_refund_intent"
                                                        [Payment.find(params[:id]), "billing_payments", :refund]
                                                      when "create_adjustment_intent"
                                                        [Invoice.find(params[:id]), "billing_invoices", :adjust]
                                                      else
                                                        raise ActiveRecord::RecordNotFound
                                                      end
    end

    def load_admin_context!
      authority_recording = operation_authority_recording
      @admin_root_recording = RecordingStudio::Recording.unscoped.find(authority_recording.root_recording_id)
      return validate_feature_override_context! if feature_override_operation?

      raise ActiveRecord::RecordNotFound unless admin_root_recording.recordable_type.in?(RecordingStudio.allowed_parent_types_for(BillingAdmin))
      return unless commercial_operation? || %w[publish_price preview_plan_update confirm_plan_update apply_plan_update reconcile_command create_refund_intent create_adjustment_intent].include?(params[:operation])

      @billing_admin_recording = RecordingStudio::Recording.unscoped.find_by!(
        root_recording_id: admin_root_recording.id, parent_recording_id: admin_root_recording.id,
        recordable_type: "RecordingStudioBilling::BillingAdmin", trashed_at: nil
      )
      validate_draft_parent_ownership! if params[:operation].start_with?("create_draft_")
      raise ActiveRecord::RecordNotFound unless belongs_to_billing_admin?(authority_recording)
    end

    def authorize_operation!
      RecordingStudioAdmin.authorize_resource!(
        key: resource_key, action: action_key, context: recording_studio_admin_context, record: operation_audit_record, audit: true
      )
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      head :forbidden
    end

    def dispatch_operation!
      case params[:operation]
      when "create_feature_override"
        RecordingStudio.record!(action: "created", recordable: operation_record, root_recording: admin_root_recording,
                                parent_recording: feature_override_account_recording, actor: current_billing_actor)
      when /\A(?:revise|supersede)_feature_override\z/
        FeatureOverrideReviser.call(recording: operation_record.recording, actor: current_billing_actor,
                                    attributes: feature_override_attributes)
      when "revoke_feature_override"
        FeatureOverrideReviser.call(recording: operation_record.recording, actor: current_billing_actor,
                                    attributes: { state: "retired" })
      when /\Acreate_draft_(.+)\z/
        RecordingStudio.record!(action: "created", recordable: operation_record,
                                root_recording: admin_root_recording, parent_recording: draft_parent_recording,
                                actor: current_billing_actor)
      when /\Arevise_(.+)\z/
        revise_commercial_record!
      when /\Aretire_(.+)\z/
        retire_commercial_record!
      when "publish_price"
        CommercialPublisher.publish!(
          root_recording: billing_admin_recording.root_recording,
          price_recording_ids: [operation_record.recording.id], actor: current_billing_actor
        )
      when "preview_plan_update"
        ApplyPlanUpdate.call(plan_update: operation_record, root_recording: billing_admin_recording.root_recording,
                             idempotency_key: "admin-preview:#{operation_record.id}")
      when "confirm_plan_update"
        ApplyPlanUpdate.call(run: operation_record, root_recording: billing_admin_recording.root_recording,
                             confirmation: { "approved_by" => current_billing_actor.id.to_s },
                             idempotency_key: operation_record.idempotency_key)
      when "apply_plan_update"
        ApplyPlanUpdate.call(run: operation_record, root_recording: billing_admin_recording.root_recording,
                             confirmation: operation_record.confirmation, idempotency_key: operation_record.idempotency_key)
      when "reconcile_command"
        ReconcileProviderCommand.call(command: operation_record)
      when "create_refund_intent"
        CreateRefundIntent.call(
          payment: operation_record, root_recording: operation_record.root_recording,
          local_idempotency_key: operation_params.fetch(:local_idempotency_key),
          amount_minor: operation_params.fetch(:amount_minor), reason: operation_params.fetch(:reason),
          metadata: operation_params.fetch(:metadata, {}), line_allocation: operation_params.fetch(:line_allocation, {}),
          tax_treatment: operation_params.fetch(:tax_treatment, "provider_default"),
          reversal_policy: operation_params.fetch(:reversal_policy, "none"), actor_reference: current_billing_actor.id.to_s
        )
      when "create_adjustment_intent"
        CreateAdjustmentIntent.call(
          invoice: operation_record, root_recording: operation_record.root_recording,
          local_idempotency_key: operation_params.fetch(:local_idempotency_key), kind: operation_params.fetch(:kind),
          amount_minor: operation_params.fetch(:amount_minor), reason: operation_params.fetch(:reason),
          metadata: operation_params.fetch(:metadata, {}), affected_reference: operation_params.fetch(:affected_reference),
          tax_treatment: operation_params.fetch(:tax_treatment, "provider_default"), actor_reference: current_billing_actor.id.to_s
        )
      end
    end

    def recording_studio_admin_context
      @recording_studio_admin_context ||= RecordingStudioAdmin::Context.new(
        params: params.to_unsafe_h, current_actor: current_billing_actor,
        controller: self, routes: self, view_context: view_context
      )
    end

    def recording_studio_admin_access_recording = admin_root_recording

    def current_root_recording
      return RecordingStudio::RootSwitchable.current_root_recording if feature_override_operation?

      admin_root_recording
    end

    def operation_authority_recording
      return feature_override_account_recording if feature_override_operation?
      return draft_parent_recording if params[:operation].start_with?("create_draft_")

      case operation_record
      when *COMMERCIAL_RESOURCES.values.map(&:last), PlanUpdate then operation_record.recording
      when PlanUpdateRun then operation_record.plan_update.recording
      when FinancialCommand then operation_record.provider_account_recording || raise(ActiveRecord::RecordNotFound)
      when Payment, Invoice then operation_record.financial_command.provider_account_recording || raise(ActiveRecord::RecordNotFound)
      end
    end

    def operation_audit_record
      return feature_override_account_recording if params[:operation] == "create_feature_override"
      return draft_parent_recording if params[:operation].start_with?("create_draft_")

      operation_record
    end

    def commercial_operation? = params[:operation].to_s.match?(/\A(?:create_draft|revise|retire)_(?:#{COMMERCIAL_RESOURCES.keys.join('|')})\z/)

    def feature_override_operation?
      params[:operation].to_s.in?(%w[create_feature_override revise_feature_override revoke_feature_override supersede_feature_override])
    end

    def load_feature_override_operation!
      @resource_key = "billing_feature_overrides"
      @action_key = params[:operation].delete_suffix("_feature_override").to_sym
      @operation_record = if params[:operation] == "create_feature_override"
                            @feature_override_account_recording = RecordingStudio::Recording.unscoped.find(params[:account_recording_id])
                            FeatureOverride.new(feature_override_creation_attributes)
                          else
                            FeatureOverride.with_current_recording.find(params[:id])
                          end
    end

    def load_commercial_operation!
      match = params[:operation].to_s.match(/\A(?<operation>create_draft|revise|retire|revoke|supersede)_(?<resource>.+)\z/)
      operation = match[:operation]
      resource_name = match[:resource]
      resource_key, model = COMMERCIAL_RESOURCES.fetch(resource_name)
      @resource_key = resource_key
      @action_key = operation == "create_draft" ? :create : operation.to_sym
      @operation_record = if operation == "create_draft"
                            @draft_parent_recording = RecordingStudio::Recording.unscoped.find(params[:parent_recording_id])
                            validate_draft_parent_type!(model, draft_parent_recording)
                            model.new(commercial_attributes(model).merge(state: "draft"))
                          else
                            model.with_current_recording.find(params[:id])
                          end
    end

    def revise_commercial_record!
      admin_root_recording.revise(operation_record.recording, actor: current_billing_actor) do |revision|
        revision.assign_attributes(commercial_attributes(operation_record.class))
      end
    end

    def retire_commercial_record!
      CommercialPublisher.retire!(retirement_recording: operation_record.recording, actor: current_billing_actor)
    end

    def commercial_attributes(model)
      attributes = params.fetch(:attributes, {}).to_unsafe_h.stringify_keys
      attributes = attributes.merge(inferred_parent_attribute(model)) { |_key, explicit, _inferred| explicit }
      attributes.transform_values! { |attribute| attribute == "" ? nil : attribute }
      allowed = model.column_names - %w[id created_at updated_at state]
      unknown = attributes.keys - allowed
      raise ArgumentError, "unsupported #{model.model_name.human.downcase} attributes: #{unknown.join(', ')}" if unknown.any?

      attributes.slice(*allowed)
    end

    def inferred_parent_attribute(model)
      parent_id = params[:parent_recording_id].presence
      return {} if parent_id.blank?

      case model.name.demodulize
      when "BillingOption" then { "product_recording_id" => parent_id }
      when "Price", "OveragePrice" then { "billing_option_recording_id" => parent_id }
      else {}
      end
    end

    def feature_override_creation_attributes
      attributes = params.fetch(:attributes, {}).to_unsafe_h
      allowed = FeatureOverride.column_names - %w[id created_at updated_at state account_recording_id]
      unknown = attributes.keys.map(&:to_s) - allowed
      raise ArgumentError, "unsupported feature override attributes: #{unknown.join(', ')}" if unknown.any?

      attributes.slice(*allowed).merge("account_recording_id" => feature_override_account_recording.id, "state" => "draft")
    end

    def feature_override_attributes
      attributes = params.fetch(:attributes, {}).to_unsafe_h.symbolize_keys
      unknown = attributes.keys - FeatureOverrideReviser::ALLOWED_ATTRIBUTES
      raise ArgumentError, "unsupported feature override attributes: #{unknown.join(', ')}" if unknown.any?

      attributes[:value] = ActiveModel::Type::Boolean.new.cast(attributes[:value]) if %w[true false].include?(attributes[:value])
      attributes
    end

    def validate_feature_override_context!
      raise ActiveRecord::RecordNotFound unless feature_override_account_recording.recordable.is_a?(Account)
      raise ActiveRecord::RecordNotFound unless feature_override_account_recording.parent_recording_id == admin_root_recording.id
      return if params[:operation] == "create_feature_override" || operation_record.account_recording_id == feature_override_account_recording.id

      raise ActiveRecord::RecordNotFound
    end

    def validate_draft_parent_type!(model, parent_recording)
      allowed_types = RecordingStudio.allowed_parent_types_for(model)
      raise ActiveRecord::RecordNotFound unless parent_recording.recordable_type.in?(allowed_types)
    end

    def validate_draft_parent_ownership!
      unless draft_parent_recording.root_recording_id == admin_root_recording.id &&
             belongs_to_billing_admin?(draft_parent_recording)
        raise ActiveRecord::RecordNotFound
      end
    end

    def operation_params
      raw = params[:attributes] || params
      (raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h).deep_symbolize_keys
    end

    def belongs_to_billing_admin?(recording)
      current = recording
      while current
        return true if current.id == billing_admin_recording.id

        current = current.parent_recording
      end
      false
    end

    def feature_override_account_recording
      @feature_override_account_recording ||= (operation_record.account_recording if operation_record.is_a?(FeatureOverride))
    end

    attr_reader :action_key, :admin_root_recording, :billing_admin_recording, :draft_parent_recording, :operation_record, :resource_key
  end
end
