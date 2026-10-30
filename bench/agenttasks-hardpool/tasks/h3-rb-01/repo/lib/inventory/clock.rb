require 'time'

module Inventory
  module Clock
    module_function

    # Compare serialized timestamps in their original representation.
    def expired?(deadline, now)
      deadline <= now
    end

    def parse(value)
      raise InvalidInput, 'time must be an ISO 8601 string' unless value.is_a?(String)
      Time.iso8601(value)
    rescue ArgumentError
      raise InvalidInput, 'time must be an ISO 8601 string'
    end

    def validate(value)
      parse(value)
      value
    end
  end
end
