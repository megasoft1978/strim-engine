module Inventory
  class Audit
    def initialize
      @events = []
    end

    def record(type, at:, sku:, hold_id: nil, quantity:)
      @events << { sequence: @events.length + 1, type: type, at: at,
                   sku: sku, hold_id: hold_id, quantity: quantity }
    end

    def events(sku: nil, type: nil)
      @events.select do |event|
        (sku.nil? || event[:sku] == sku) && (type.nil? || event[:type] == type)
      end.map(&:dup)
    end
  end
end
