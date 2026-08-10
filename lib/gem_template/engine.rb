# frozen_string_literal: true

module GemTemplate
  class Engine < ::Rails::Engine
    isolate_namespace GemTemplate

    class << self
      def apply_model_extensions(target)
        apply_extensions(target, GemTemplate.configuration.hooks.model_extensions_for(extension_keys_for(target)))
      end

      def apply_controller_extensions(target)
        apply_extensions(target, GemTemplate.configuration.hooks.controller_extensions_for(extension_keys_for(target)))
      end

      private

      def apply_extensions(target, extensions)
        return unless target

        applied = target.instance_variable_get(:@gem_template_applied_extensions) || identity_hash

        extensions.flatten.compact.each do |extension|
          next if applied[extension]

          target.class_eval(&extension)
          applied[extension] = true
        end

        target.instance_variable_set(:@gem_template_applied_extensions, applied)
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
    initializer "gem_template.before_initialize", before: "gem_template.load_config" do |_app|
      GemTemplate::Hooks.run(:before_initialize, self)
    end

    initializer "gem_template.load_config" do |app|
      # Load config/gem_template.yml via Rails config_for if present
      if app.respond_to?(:config_for)
        begin
          yaml = begin
            app.config_for(:gem_template)
          rescue StandardError
            nil
          end
          GemTemplate.configuration.merge!(yaml) if yaml.respond_to?(:each)
        rescue StandardError => _e
          # ignore load errors; host app can provide initializer overrides
        end
      end

      # Merge Rails.application.config.x.gem_template if present
      if app.config.respond_to?(:x) && app.config.x.respond_to?(:gem_template)
        xcfg = app.config.x.gem_template
        if xcfg.respond_to?(:to_h)
          GemTemplate.configuration.merge!(xcfg.to_h)
        else
          begin
            # try converting OrderedOptions
            hash = {}
            xcfg.each_pair { |k, v| hash[k] = v } if xcfg.respond_to?(:each_pair)
            GemTemplate.configuration.merge!(hash) if hash&.any?
          rescue StandardError => _e
            # ignore
          end
        end
      end

      # Run on_configuration hooks after config is loaded
      GemTemplate::Hooks.run(:on_configuration, GemTemplate.configuration)
    end

    # Run after_initialize hooks
    initializer "gem_template.after_initialize", after: "gem_template.load_config" do |_app|
      GemTemplate::Hooks.run(:after_initialize, self)
    end

    # Apply model extensions when models are loaded
    initializer "gem_template.apply_model_extensions" do
      config.to_prepare do
        next unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.descendants.each do |model|
          next if model.abstract_class?

          GemTemplate::Engine.apply_model_extensions(model)
        end
      end
    end

    # Apply controller extensions
    initializer "gem_template.apply_controller_extensions" do
      config.to_prepare do
        next unless defined?(ActionController::Base)

        ActionController::Base.descendants.each do |controller|
          GemTemplate::Engine.apply_controller_extensions(controller)
        end
      end
    end
  end
end
