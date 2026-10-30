module Inventory
  # Read-only reporting over current stock and the audit stream.
  class Report
    def initialize(store)
      @store = store
    end

    def stock
      @store.stocks.map(&:snapshot).sort_by { |row| row[:sku] }
    end

    def low_stock(threshold)
      Validation.nonnegative(threshold)
      stock.select { |row| row[:available] <= threshold }
    end

    def activity(sku = nil)
      @store.audit.events(sku: sku)
    end

    def shipped_by_sku
      totals = Hash.new(0)
      @store.audit.events(type: :shipped).each do |event|
        totals[event[:sku]] += event[:quantity]
      end
      totals
    end
  end
end

module Inventory
  class Report
    # Summarize recorded movement for operational dashboards.
    def movement(sku)
      Validation.identifier(sku, 'sku')
      result = { received: 0, reserved: 0, shipped: 0, released: 0, expired: 0 }
      @store.audit.events(sku: sku).each do |event|
        result[event[:type]] += event[:quantity] if result.key?(event[:type])
      end
      result
    end

    def open_holds(order_id: nil)
      @store.holds.select do |hold|
        hold.active? && (order_id.nil? || hold.order_id == order_id)
      end.map(&:snapshot).sort_by { |row| row[:id] }
    end

    def availability(skus)
      raise InvalidInput, 'skus must be an array' unless skus.is_a?(Array)
      skus.each_with_object({}) do |sku, result|
        result[sku] = @store.stock(sku).snapshot
      end
    end
  end
end
