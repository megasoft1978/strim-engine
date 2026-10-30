module Inventory
  class Stock
    attr_reader :sku, :on_hand, :reserved

    def initialize(sku)
      @sku = Validation.identifier(sku, 'sku')
      @on_hand = 0
      @reserved = 0
    end

    def available
      on_hand - reserved
    end

    def receive(quantity)
      @on_hand += Validation.quantity(quantity)
    end

    def reserve(quantity)
      Validation.quantity(quantity)
      raise InsufficientStock, 'not enough available stock' if quantity > available
      @reserved += quantity
    end

    def ship(quantity)
      Validation.quantity(quantity)
      raise Conflict, 'shipment exceeds reserved stock' if quantity > reserved
      @reserved -= quantity
      @on_hand -= quantity
    end

    def release(quantity)
      Validation.quantity(quantity)
      @reserved -= quantity
    end

    def snapshot
      { sku: sku, on_hand: on_hand, reserved: reserved, available: available }
    end
  end
end
