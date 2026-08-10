> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** December 11, 2025
>
> *Maintainers: Please update the date above when modifying this file.*

---

# Engine Hooks

GemTemplate provides a powerful hook system that allows host applications to customize engine behavior without modifying the engine's source code.

---

## Available Hooks

### Lifecycle Hooks

| Hook | When it runs |
|------|--------------|
| `before_initialize` | Before the engine initializes |
| `after_initialize` | After the engine initializes |
| `on_configuration` | When configuration is applied |

### Service Hooks

| Hook | When it runs |
|------|--------------|
| `before_service` | Before any service executes |
| `after_service` | After any service completes |
| `around_service` | Wraps service execution |

---

## Registering Hooks

### Block Syntax

```ruby
# config/initializers/gem_template.rb
GemTemplate.configure do |config|
  config.hooks.after_initialize do
    Rails.logger.info "GemTemplate initialized!"
  end
  
  config.hooks.before_service do |service_class, args|
    Rails.logger.debug "Calling #{service_class} with #{args}"
  end
end
```

### Class Syntax

```ruby
# app/hooks/gem_template_audit_hook.rb
class GemTemplateAuditHook
  def call(service_class, result)
    AuditLog.create!(
      service: service_class.name,
      success: result.success?,
      timestamp: Time.current
    )
  end
end

# config/initializers/gem_template.rb
GemTemplate.configure do |config|
  config.hooks.after_service GemTemplateAuditHook.new
end
```

---

## Extending Models

Add associations, validations, or methods to engine models:

```ruby
GemTemplate.configure do |config|
  config.hooks.extend_model :Example do
    include Auditable
    
    belongs_to :organization
    validates :organization, presence: true
    
    def custom_method
      # Your logic here
    end
  end
end
```

---

## Extending Controllers

Add before_actions, concerns, or methods to engine controllers:

```ruby
GemTemplate.configure do |config|
  config.hooks.extend_controller :HomeController do
    before_action :authenticate_user!
    
    include YourConcern
  end
end
```

---

## Service Hooks Examples

### Wrap Services in Transactions

```ruby
GemTemplate.configure do |config|
  config.hooks.around_service do |service, block|
    ActiveRecord::Base.transaction do
      block.call
    end
  end
end
```

### Log All Service Calls

```ruby
GemTemplate.configure do |config|
  config.hooks.before_service do |service_class, args|
    Rails.logger.info "[GemTemplate] #{service_class.name} called"
  end
  
  config.hooks.after_service do |service_class, result|
    status = result.success? ? "succeeded" : "failed"
    Rails.logger.info "[GemTemplate] #{service_class.name} #{status}"
  end
end
```

### Add Metrics/Instrumentation

```ruby
GemTemplate.configure do |config|
  config.hooks.around_service do |service, block|
    start_time = Time.current
    result = block.call
    duration = Time.current - start_time
    
    StatsD.measure("gem_template.#{service.class.name.demodulize.underscore}", duration)
    result
  end
end
```

---

## Custom Hooks

The engine triggers custom hooks at specific points. You can listen for these:

```ruby
GemTemplate.configure do |config|
  config.hooks.on :example_created do |example|
    Notifier.notify_admin(example)
  end
  
  config.hooks.on :example_updated do |example, changes|
    AuditLog.record(example, changes)
  end
end
```

---

## View Hooks

### Content Injection Points

Engine views include content injection points:

```erb
<%# In your host app layouts or views %>
<% content_for :gem_template_header do %>
  <div class="custom-header">Your custom header</div>
<% end %>

<% content_for :gem_template_footer do %>
  <div class="custom-footer">Your custom footer</div>
<% end %>
```

### Partial Overrides

Override engine partials by creating matching files in your host app:

```
app/views/gem_template/home/_sidebar.html.erb  # Overrides engine partial
```

---

## Hook Priority

Hooks run in the order they're registered. To control order:

```ruby
GemTemplate.configure do |config|
  config.hooks.after_initialize priority: 10 do
    # Runs first (lower = earlier)
  end
  
  config.hooks.after_initialize priority: 20 do
    # Runs second
  end
end
```

---

## Error Handling

By default, hook errors are logged but don't stop execution. To change this:

```ruby
GemTemplate.configure do |config|
  config.hooks.raise_on_error = true  # Raise exceptions from hooks
end
```

---

## Testing Hooks

```ruby
# test/hooks_test.rb
class HooksTest < ActiveSupport::TestCase
  setup do
    @called = false
    GemTemplate.configuration.hooks.after_initialize { @called = true }
  end
  
  test "after_initialize hook is called" do
    GemTemplate::Hooks.run(:after_initialize)
    assert @called
  end
end
```

---

## Best Practices

1. **Keep hooks lightweight** - Heavy processing should be queued as background jobs
2. **Handle errors gracefully** - Don't let hook failures break core functionality  
3. **Document custom hooks** - When adding hooks in services, document them
4. **Test hooks in isolation** - Write unit tests for hook behavior
5. **Use around hooks sparingly** - They add complexity; prefer before/after

---

## Available Extension Points

| Component | Extension Method |
|-----------|------------------|
| Models | `config.hooks.extend_model :ModelName` |
| Controllers | `config.hooks.extend_controller :ControllerName` |
| Services | `before_service`, `after_service`, `around_service` |
| Views | `content_for` blocks, partial overrides |
| Lifecycle | `before_initialize`, `after_initialize` |
| Custom | `config.hooks.on :event_name` |
