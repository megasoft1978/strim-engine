module Inventory
  module Validation
    module_function

    def identifier(value, label)
      unless value.is_a?(String) && !value.strip.empty?
        raise InvalidInput, "#{label} must be a nonempty string"
      end
      value
    end

    def quantity(value)
      unless value.is_a?(Integer) && value.positive?
        raise InvalidInput, 'quantity must be a positive integer'
      end
      value
    end

    def nonnegative(value)
      unless value.is_a?(Integer) && value >= 0
        raise InvalidInput, 'quantity must be a nonnegative integer'
      end
      value
    end
  end
end
