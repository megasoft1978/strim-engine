module Inventory
  class Store
    attr_reader :audit

    def initialize
      @stocks = {}
      @holds = {}
      @audit = Audit.new
    end

    def stock(sku)
      Validation.identifier(sku, 'sku')
      @stocks[sku] ||= Stock.new(sku)
    end

    def hold(id)
      @holds.fetch(id) { raise NotFound, "unknown hold #{id}" }
    end

    def add_hold(hold)
      raise Conflict, 'hold id already exists' if @holds.key?(hold.id)
      @holds[hold.id] = hold
    end

    def hold_exists?(id)
      @holds.key?(id)
    end

    def holds
      @holds.values
    end

    def stocks
      @stocks.values
    end
  end
end
