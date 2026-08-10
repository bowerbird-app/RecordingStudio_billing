# frozen_string_literal: true

require "test_helper"

class HooksTest < Minitest::Test
  def setup
    @hooks = GemTemplate::Hooks.new
  end

  def teardown
    @hooks.clear!
  end

  # === Registration Tests ===

  def test_before_initialize_registration
    called = false
    @hooks.before_initialize { called = true }

    assert @hooks.registered?(:before_initialize)
    @hooks.run(:before_initialize)
    assert called
  end

  def test_after_initialize_registration
    called = false
    @hooks.after_initialize { called = true }

    assert @hooks.registered?(:after_initialize)
    @hooks.run(:after_initialize)
    assert called
  end

  def test_on_configuration_registration
    called = false
    @hooks.on_configuration { called = true }

    assert @hooks.registered?(:on_configuration)
    @hooks.run(:on_configuration)
    assert called
  end

  def test_before_service_registration
    called = false
    @hooks.before_service { called = true }

    assert @hooks.registered?(:before_service)
    @hooks.run(:before_service)
    assert called
  end

  def test_after_service_registration
    called = false
    @hooks.after_service { called = true }

    assert @hooks.registered?(:after_service)
    @hooks.run(:after_service)
    assert called
  end

  def test_around_service_registration
    @hooks.around_service do |_service, block|
      block.call
    end

    assert @hooks.registered?(:around_service)
  end

  def test_custom_event_registration
    called = false
    @hooks.on(:custom_event) { called = true }

    assert @hooks.registered?(:custom_event)
    @hooks.run(:custom_event)
    assert called
  end

  # === Handler Tests ===

  def test_handler_object_registration
    handler = Object.new
    def handler.call
      @called = true
    end

    def handler.called?
      @called
    end

    @hooks.after_initialize(handler)
    @hooks.run(:after_initialize)

    assert handler.called?
  end

  def test_handler_receives_arguments
    received_args = nil
    @hooks.before_service { |*args| received_args = args }

    @hooks.run(:before_service, "ServiceClass", { name: "test" })

    assert_equal ["ServiceClass", { name: "test" }], received_args
  end

  def test_registration_without_handler_or_block_is_noop
    @hooks.after_initialize

    refute @hooks.registered?(:after_initialize)
  end

  def test_handler_with_to_proc_only_executes
    handler = Object.new
    handler.define_singleton_method(:to_proc) do
      proc { |value| value * 2 }
    end

    @hooks.on(:custom_event, handler)

    assert_equal [6], @hooks.run(:custom_event, 3)
  end

  def test_run_returns_results_in_priority_order
    @hooks.after_initialize(priority: 20) { :second }
    @hooks.after_initialize(priority: 10) { :first }

    assert_equal %i[first second], @hooks.run(:after_initialize)
  end

  # === Priority Tests ===

  def test_hooks_run_in_priority_order
    order = []

    @hooks.after_initialize(priority: 30) { order << 3 }
    @hooks.after_initialize(priority: 10) { order << 1 }
    @hooks.after_initialize(priority: 20) { order << 2 }

    @hooks.run(:after_initialize)

    assert_equal [1, 2, 3], order
  end

  def test_default_priority_is_100
    order = []

    @hooks.after_initialize(priority: 50) { order << "early" }
    @hooks.after_initialize { order << "default" }
    @hooks.after_initialize(priority: 150) { order << "late" }

    @hooks.run(:after_initialize)

    assert_equal %w[early default late], order
  end

  # === Around Hooks Tests ===

  def test_around_hook_wraps_execution
    events = []

    @hooks.around_service do |_service, block|
      events << :before
      result = block.call
      events << :after
      result
    end

    result = @hooks.run_around(:around_service, "service") do
      events << :inside
      "result"
    end

    assert_equal %i[before inside after], events
    assert_equal "result", result
  end

  def test_multiple_around_hooks_nest_correctly
    events = []

    @hooks.around_service(priority: 10) do |_service, block|
      events << :outer_before
      result = block.call
      events << :outer_after
      result
    end

    @hooks.around_service(priority: 20) do |_service, block|
      events << :inner_before
      result = block.call
      events << :inner_after
      result
    end

    @hooks.run_around(:around_service, "service") do
      events << :core
    end

    assert_equal %i[outer_before inner_before core inner_after outer_after], events
  end

  def test_run_around_without_hooks_executes_block
    result = @hooks.run_around(:around_service, "service") do
      "direct result"
    end

    assert_equal "direct result", result
  end

  # === Model/Controller Extensions ===

  def test_extend_model_registration
    @hooks.extend_model(:Example) do
      def custom_method; end
    end

    extensions = @hooks.model_extensions_for(:Example)
    assert_equal 1, extensions.size
    assert extensions.first.is_a?(Proc)
  end

  def test_extend_controller_registration
    @hooks.extend_controller(:HomeController) do
      def custom_action; end
    end

    extensions = @hooks.controller_extensions_for(:HomeController)
    assert_equal 1, extensions.size
    assert extensions.first.is_a?(Proc)
  end

  def test_multiple_extensions_for_same_model
    @hooks.extend_model(:Example) { def method1; end }
    @hooks.extend_model(:Example) { def method2; end }

    extensions = @hooks.model_extensions_for(:Example)
    assert_equal 2, extensions.size
  end

  def test_extend_model_without_block_is_noop
    @hooks.extend_model(:Example)

    assert_empty @hooks.model_extensions_for(:Example)
  end

  def test_extend_controller_without_block_is_noop
    @hooks.extend_controller(:HomeController)

    assert_empty @hooks.controller_extensions_for(:HomeController)
  end

  def test_extensions_for_multiple_names_are_flattened
    @hooks.extend_model(:Example) { :example }
    @hooks.extend_model(:SharedExample) { :shared }
    @hooks.extend_controller(:HomeController) { :home }
    @hooks.extend_controller(:AdminHomeController) { :admin_home }

    assert_equal 2, @hooks.model_extensions_for(%i[Example SharedExample]).size
    assert_equal 2, @hooks.controller_extensions_for(%i[HomeController AdminHomeController]).size
  end

  # === Error Handling Tests ===

  def test_hook_error_does_not_stop_other_hooks_by_default
    results = []

    @hooks.after_initialize(priority: 10) { results << 1 }
    @hooks.after_initialize(priority: 20) { raise "test error" }
    @hooks.after_initialize(priority: 30) { results << 3 }

    @hooks.run(:after_initialize)

    assert_equal [1, 3], results
  end

  def test_raise_on_error_raises_hook_error
    @hooks.raise_on_error = true
    @hooks.after_initialize { raise "test error" }

    assert_raises(GemTemplate::Hooks::HookError) do
      @hooks.run(:after_initialize)
    end
  end

  def test_hook_errors_are_logged_when_logger_is_available
    logger = Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def error(message)
        @messages << message
      end
    end.new
    error = RuntimeError.new("logged error")
    error.set_backtrace(%w[line1 line2 line3 line4 line5 line6])

    @hooks.after_initialize { raise error }

    Rails.stub(:logger, logger) do
      @hooks.run(:after_initialize)
    end

    assert_includes logger.messages.first, "logged error"
    assert_equal "line1\nline2\nline3\nline4\nline5", logger.messages.last
  end

  # === Clear Tests ===

  def test_clear_removes_all_hooks
    @hooks.after_initialize {}
    @hooks.before_service {}
    @hooks.extend_model(:Example) {}

    @hooks.clear!

    refute @hooks.registered?(:after_initialize)
    refute @hooks.registered?(:before_service)
    assert_empty @hooks.model_extensions_for(:Example)
  end

  def test_clear_specific_event
    @hooks.after_initialize {}
    @hooks.before_service {}

    @hooks.clear(:after_initialize)

    refute @hooks.registered?(:after_initialize)
    assert @hooks.registered?(:before_service)
  end

  # === Class Method Tests ===

  def test_class_run_delegates_to_configuration
    GemTemplate.configuration.hooks
    called = false

    GemTemplate.configuration.hooks.after_initialize { called = true }
    GemTemplate::Hooks.run(:after_initialize)

    assert called
  ensure
    GemTemplate.configuration.hooks.clear!
  end

  def test_class_trigger_is_alias_for_run
    called = false
    GemTemplate.configuration.hooks.on(:custom_event) { called = true }

    GemTemplate::Hooks.trigger(:custom_event)

    assert called
  ensure
    GemTemplate.configuration.hooks.clear!
  end

  def test_class_run_around_delegates_to_configuration
    events = []
    GemTemplate.configuration.hooks.around_service do |_context, block|
      events << :around
      block.call
    end

    result = GemTemplate::Hooks.run_around(:around_service, :service) do
      events << :core
      :ok
    end

    assert_equal %i[around core], events
    assert_equal :ok, result
  ensure
    GemTemplate.configuration.hooks.clear!
  end
end
