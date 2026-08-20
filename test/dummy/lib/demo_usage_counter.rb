# frozen_string_literal: true

module DemoUsageCounter
  class << self
    def project_count(root)
      counts.fetch(root.id, 0)
    end

    def set!(root, value)
      counts[root.id] = Integer(value)
    end

    def increment!(root)
      counts[root.id] = project_count(root) + 1
    end

    def reset!
      counts.clear
    end

    private

    def counts
      @counts ||= {}
    end
  end
end
