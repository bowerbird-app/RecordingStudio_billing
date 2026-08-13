# frozen_string_literal: true

module RecordingStudioBilling
  class Engine < ::Rails::Engine
    isolate_namespace RecordingStudioBilling

    class << self
      def apply_model_extensions(target)
        extensions = RecordingStudioBilling.configuration.hooks.model_extensions_for(extension_keys_for(target))
        apply_extensions(target, extensions)
      end

      def apply_controller_extensions(target)
        extensions = RecordingStudioBilling.configuration.hooks.controller_extensions_for(extension_keys_for(target))
        apply_extensions(target, extensions)
      end

      private

      def apply_extensions(target, extensions)
        return unless target

        applied = target.instance_variable_get(:@recording_studio_billing_applied_extensions) || identity_hash

        extensions.flatten.compact.each do |extension|
          next if applied[extension]

          target.class_eval(&extension)
          applied[extension] = true
        end

        target.instance_variable_set(:@recording_studio_billing_applied_extensions, applied)
      end

      def extension_keys_for(target)
        names = [target.name, target.name&.demodulize].compact.uniq
        names.map(&:to_sym)
      end

      def identity_hash
        {}.compare_by_identity
      end
    end

    # Run before_initialize hooks
    initializer "recording_studio_billing.before_initialize", before: "recording_studio_billing.load_config" do |_app|
      RecordingStudioBilling::Hooks.run(:before_initialize, self)
    end

    initializer "recording_studio_billing.load_config" do |app|
      # Load config/recording_studio_billing.yml via Rails config_for if present.
      if app.respond_to?(:config_for)
        configuration_file = File.join(app.paths["config"].first, "recording_studio_billing.yml")
        if File.exist?(configuration_file)
          yaml = app.config_for(:recording_studio_billing)
          RecordingStudioBilling.configuration.merge!(yaml) unless yaml.nil?
        end
      end

      # Merge Rails.application.config.x.recording_studio_billing if present.
      if app.config.respond_to?(:x) && app.config.x.respond_to?(:recording_studio_billing)
        xcfg = app.config.x.recording_studio_billing
        if xcfg.respond_to?(:to_h)
          RecordingStudioBilling.configuration.merge!(xcfg.to_h)
        else
          raise ArgumentError, "commercial configuration must be enumerable" unless xcfg.respond_to?(:each_pair)

          hash = {}
          xcfg.each_pair { |k, v| hash[k] = v }
          RecordingStudioBilling.configuration.merge!(hash) if hash.any?
        end
      end

      # Run on_configuration hooks after config is loaded
      RecordingStudioBilling::Hooks.run(:on_configuration, RecordingStudioBilling.configuration)
    end

    # Run after_initialize hooks
    initializer "recording_studio_billing.after_initialize", after: "recording_studio_billing.load_config" do |_app|
      RecordingStudioBilling::Hooks.run(:after_initialize, self)
    end

    initializer "recording_studio_billing.stripe_content_security_policy",
                after: "recording_studio_billing.load_config" do |app|
      next unless app.config.respond_to?(:content_security_policy)

      app.config.content_security_policy do |policy|
        policy.frame_src :self, *StripeAdapter::STRIPE_BROWSER_ORIGINS
        policy.script_src :self, "https://js.stripe.com"
        policy.connect_src :self, "https://api.stripe.com", "https://r.stripe.com"
      end
    end

    initializer "recording_studio_billing.register_capabilities", before: "recording_studio.load_config" do
      RecordingStudioBilling.register_capabilities!
    end

    initializer "recording_studio_billing.register_admin_definitions" do
      next unless defined?(RecordingStudioAdmin)

      [
        RecordingStudioBilling::BillingCommercialSection,
        RecordingStudioBilling::BillingFinancialSection,
        RecordingStudioBilling::BillingOperationsSection
      ].each { |section| RecordingStudioAdmin.register_section(section) }

      [
        RecordingStudioBilling::BillingCommercialScreen,
        RecordingStudioBilling::BillingFinancialScreen,
        RecordingStudioBilling::BillingOperationsScreen,
        *RecordingStudioBilling::ADMIN_OPERATION_SCREEN_CLASSES
      ].each { |screen| RecordingStudioAdmin.register_screen(screen) }

      [
        RecordingStudioBilling::BillingCommercialResource,
        RecordingStudioBilling::BillingFinancialResource,
        RecordingStudioBilling::BillingOperationsResource,
        *RecordingStudioBilling::ADMIN_OPERATION_RESOURCE_CLASSES
      ].each { |resource| RecordingStudioAdmin.register_resource(resource) }
    end

    config.to_prepare do
      RecordingStudioBilling.register_builtin_providers!
      RecordingStudioBilling.register_webhook_actions!
    end

    initializer "recording_studio_billing.register_recordable_types", after: "recording_studio.load_config" do
      RecordingStudioBilling::RECORDABLE_TYPES.each do |type|
        RecordingStudio.register_recordable_type(type)
      end
    end

    # Apply model extensions when models are loaded
    initializer "recording_studio_billing.apply_model_extensions" do
      config.to_prepare do
        next unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.descendants.each do |model|
          next if model.abstract_class?

          RecordingStudioBilling::Engine.apply_model_extensions(model)
        end
      end
    end

    # Apply controller extensions
    initializer "recording_studio_billing.apply_controller_extensions" do
      config.to_prepare do
        next unless defined?(ActionController::Base)

        ActionController::Base.descendants.each do |controller|
          RecordingStudioBilling::Engine.apply_controller_extensions(controller)
        end
      end
    end
  end
end
