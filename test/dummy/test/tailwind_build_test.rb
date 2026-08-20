# frozen_string_literal: true

require_relative "test_helper"

class TailwindBuildTest < ActiveSupport::TestCase
  test "compiled tailwind includes Flatpack sidebar layout utilities" do
    css_path = Rails.root.join("app/assets/builds/tailwind.css")
    assert css_path.file?, "expected #{css_path} after bin/rails tailwindcss:build"

    css = css_path.read
    assert_includes css, "h-screen"
    assert_includes css, "w-64"
    assert_match(/grid-cols-\\?\[auto[_-]1fr\\?\]/, css)
  end
end
