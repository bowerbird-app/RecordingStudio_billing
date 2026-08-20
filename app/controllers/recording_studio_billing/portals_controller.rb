# frozen_string_literal: true

module RecordingStudioBilling
  class PortalsController < ApplicationController
    def portal
      authorize_billing_action!(:edit_billing_settings)
      context = portal_context
      adapter = RecordingStudioBilling.provider_adapter(context.fetch(:adapter_key))
      raise ActiveRecord::RecordNotFound unless adapter.respond_to?(:portal_session)

      session = adapter.portal_session(
        customer_reference: context.fetch(:customer_reference),
        return_url: billing_settings_url,
        features: RestrictedPortal.validate_features!(context[:features]),
        **context.fetch(:options, {}).to_h.symbolize_keys.except(:features)
      )
      raise ActiveRecord::RecordNotFound unless session.is_a?(Hash)

      portal_url = session[:url]
      raise ActiveRecord::RecordNotFound unless trusted_portal_url?(portal_url, adapter)

      redirect_to portal_url, allow_other_host: true
    rescue ArgumentError, KeyError, NoMethodError, URI::InvalidURIError
      raise ActiveRecord::RecordNotFound
    end

    private

    def portal_context
      resolver = RecordingStudioBilling.configuration.billing_portal_context_resolver
      raise ActiveRecord::RecordNotFound unless resolver

      context = resolver.call(
        root_recording: root_recording,
        account_recording: account_recording,
        subscriptions: Subscription.for_root(root_recording).where(account_recording: account_recording)
      )
      context = context.to_h.symbolize_keys
      raise ActiveRecord::RecordNotFound if context[:adapter_key].blank? || context[:customer_reference].blank?

      context.slice(:adapter_key, :customer_reference, :features).merge(options: context[:options] || {})
    rescue ArgumentError, KeyError, NoMethodError
      raise ActiveRecord::RecordNotFound
    end

    def billing_settings_url
      url_for(controller: "/recording_studio_billing/billing", action: :settings, only_path: false)
    end

    def trusted_portal_url?(url, adapter)
      return false unless adapter.respond_to?(:trusted_portal_origins)

      portal_uri = URI.parse(url.to_s)
      return false unless portal_uri.host.present? && portal_uri.userinfo.blank?
      return false unless Rails.env.local? || portal_uri.scheme == "https"

      portal_origin = origin_components(portal_uri)
      Array(adapter.trusted_portal_origins).any? do |origin|
        trusted_uri = URI.parse(origin.to_s)
        trusted_origin?(trusted_uri) && origin_components(trusted_uri) == portal_origin
      rescue URI::InvalidURIError
        false
      end
    end

    def trusted_origin?(uri)
      uri.scheme.in?(%w[http https]) && uri.host.present? && uri.userinfo.blank? &&
        uri.path.in?(["", "/"]) && uri.query.blank? && uri.fragment.blank?
    end

    def origin_components(uri)
      [uri.scheme.downcase, uri.host.downcase, uri.port]
    end
  end
end
