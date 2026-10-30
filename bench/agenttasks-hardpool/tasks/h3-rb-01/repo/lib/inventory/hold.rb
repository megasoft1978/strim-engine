module Inventory
  class Hold
    attr_reader :id, :sku, :order_id, :quantity, :remaining, :expires_at, :status

    def initialize(id:, sku:, order_id:, quantity:, expires_at:)
      @id = Validation.identifier(id, 'hold id')
      @sku = Validation.identifier(sku, 'sku')
      @order_id = Validation.identifier(order_id, 'order id')
      @quantity = Validation.quantity(quantity)
      @remaining = quantity
      @expires_at = Clock.validate(expires_at)
      @status = :active
    end

    def active?
      status == :active
    end

    def expired?(now)
      active? && Clock.expired?(expires_at, now)
    end

    def ship(quantity)
      raise Conflict, 'hold is not active' unless active?
      Validation.quantity(quantity)
      raise Conflict, 'quantity exceeds hold' if quantity > remaining
      @remaining -= quantity
      @status = :fulfilled if remaining.zero?
    end

    def release(status = :released)
      amount = remaining
      @status = status if active?
      amount
    end

    def snapshot
      { id: id, sku: sku, order_id: order_id, quantity: quantity,
        remaining: remaining, expires_at: expires_at, status: status }
    end
  end
end
