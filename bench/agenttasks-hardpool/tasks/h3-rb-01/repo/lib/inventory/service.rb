module Inventory
  class Service
    attr_reader :store

    def initialize(store = Store.new)
      @store = store
    end

    def receive(sku, quantity, at:)
      Clock.validate(at)
      item = store.stock(sku)
      item.receive(quantity)
      store.audit.record(:received, at: at, sku: sku, quantity: quantity)
      item.snapshot
    end

    def reserve(id:, sku:, order_id:, quantity:, expires_at:, at:)
      Clock.validate(at)
      candidate = Hold.new(id: id, sku: sku, order_id: order_id,
                           quantity: quantity, expires_at: expires_at)
      raise Conflict, 'hold id already exists' if store.hold_exists?(id)
      raise InvalidInput, 'expiry must be in the future' if Clock.expired?(expires_at, at)
      expire(at: at)
      item = store.stock(sku)
      item.reserve(quantity)
      store.add_hold(candidate)
      store.audit.record(:reserved, at: at, sku: sku, hold_id: id, quantity: quantity)
      candidate.snapshot
    end

    def ship(id, quantity, at:)
      Clock.validate(at)
      expire(at: at)
      hold = store.hold(id)
      hold.ship(quantity)
      store.stock(hold.sku).ship(quantity)
      store.audit.record(:shipped, at: at, sku: hold.sku, hold_id: id, quantity: quantity)
      hold.snapshot
    end

    def release(id, at:)
      Clock.validate(at)
      expire(at: at)
      hold = store.hold(id)
      amount = hold.release
      if amount.positive?
        store.stock(hold.sku).release(amount)
        store.audit.record(:released, at: at, sku: hold.sku, hold_id: id, quantity: amount)
      end
      hold.snapshot
    end

    def expire(at:)
      Clock.validate(at)
      store.holds.each do |hold|
        next unless hold.expired?(at)
        amount = hold.release(:expired)
        store.stock(hold.sku).release(amount)
        store.audit.record(:expired, at: at, sku: hold.sku, hold_id: hold.id, quantity: amount)
      end
    end

    def stock(sku, at:)
      Clock.validate(at)
      expire(at: at)
      store.stock(sku).snapshot
    end

    def report
      Report.new(store)
    end
  end
end
