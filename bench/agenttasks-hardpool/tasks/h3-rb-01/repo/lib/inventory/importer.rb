require 'csv'

module Inventory
  # Import receipts from a CSV with sku and quantity headers.
  class Importer
    def initialize(service)
      @service = service
    end

    def receipts(csv, at:)
      rows = CSV.parse(csv, headers: true)
      unless rows.headers && %w[sku quantity].all? { |key| rows.headers.include?(key) }
        raise InvalidInput, 'expected sku and quantity headers'
      end
      # Validate all rows before applying any of them.
      entries = rows.map do |row|
        sku = Validation.identifier(row['sku'], 'sku')
        begin
          quantity = Integer(row['quantity'], 10)
        rescue ArgumentError, TypeError
          raise InvalidInput, 'invalid quantity'
        end
        [sku, Validation.quantity(quantity)]
      end
      Clock.validate(at)
      entries.each { |sku, quantity| @service.receive(sku, quantity, at: at) }
      entries.length
    end
  end
end
