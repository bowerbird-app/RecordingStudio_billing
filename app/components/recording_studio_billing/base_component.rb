# frozen_string_literal: true

module RecordingStudioBilling
  class BaseComponent < ViewComponent::Base
    renders_many :header_extensions
    renders_many :body_extensions
    renders_many :footer_extensions

    private

    def render_extension(content)
      content.respond_to?(:render_in) ? helpers.render(content) : content
    end
  end
end
