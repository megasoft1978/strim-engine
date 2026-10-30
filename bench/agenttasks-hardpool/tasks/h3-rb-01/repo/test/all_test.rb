require 'minitest/autorun'
require 'inventory'

class InventoryTest < Minitest::Test
  def setup
    @service = Inventory::Service.new
    @start = '2026-01-01T10:00:00Z'
    @service.receive('A', 20, at: @start)
  end

  def reserve(id = 'h1', quantity: 8, expiry: '2026-01-01T12:00:00Z')
    @service.reserve(id: id, sku: 'A', order_id: 'order', quantity: quantity,
                     expires_at: expiry, at: @start)
  end

  def test_order_availability_after_customer_actions
    reserve
    @service.ship('h1', 3, at: '2026-01-01T10:30:00Z')
    @service.release('h1', at: '2026-01-01T11:00:00Z')
    @service.release('h1', at: '2026-01-01T11:01:00Z')
    assert_equal({ sku: 'A', on_hand: 17, reserved: 0, available: 17 },
                 @service.stock('A', at: '2026-01-01T11:02:00Z'))
    assert_equal [5], @service.report.activity('A').select { |e| e[:type] == :released }.map { |e| e[:quantity] }
  end

  def test_stock_changes_at_the_hold_deadline
    reserve('h1', expiry: '2026-01-02T00:30:00+02:00')
    assert_equal 8, @service.stock('A', at: '2026-01-01T22:29:59Z')[:reserved]
    assert_equal 0, @service.stock('A', at: '2026-01-01T22:30:00Z')[:reserved]
    assert_equal 1, @service.report.activity('A').count { |e| e[:type] == :expired }
  end

  def test_hold_accepted_for_future_deadline
    @service.reserve(id: 'h', sku: 'A', order_id: 'o', quantity: 2,
                     at: '2026-01-01T10:00:00Z', expires_at: '2026-01-01T09:30:00-01:00')
    assert_equal 2, @service.stock('A', at: '2026-01-01T10:15:00Z')[:reserved]
  end

  def test_stock_after_deadline_and_customer_action
    reserve
    @service.release('h1', at: '2026-01-01T12:00:00Z')
    assert_equal 20, @service.stock('A', at: '2026-01-01T12:01:00Z')[:available]
    assert_equal [:received, :reserved, :expired], @service.report.activity.map { |e| e[:type] }
  end

  def test_fulfilment_and_insufficient_stock
    reserve(quantity: 8)
    assert_raises(Inventory::InsufficientStock) { reserve('h2', quantity: 13) }
    @service.ship('h1', 8, at: @start)
    assert_equal 12, @service.stock('A', at: @start)[:on_hand]
    assert_raises(Inventory::Conflict) { @service.ship('h1', 1, at: @start) }
  end

  def test_rejects_invalid_operations_without_partial_mutation
    assert_raises(Inventory::InvalidInput) { reserve(quantity: 0) }
    reserve
    assert_raises(Inventory::Conflict) { @service.ship('h1', 9, at: @start) }
    assert_raises(Inventory::Conflict) { reserve }
    assert_equal 8, @service.stock('A', at: @start)[:reserved]
  end

  def test_reports_and_snapshots_are_detached
    reserve
    @service.ship('h1', 2, at: @start)
    event = @service.report.activity.first
    event[:quantity] = 999
    assert_equal 20, @service.report.movement('A')[:received]
    assert_equal({ 'A' => 2 }, @service.report.shipped_by_sku)
    assert_equal 6, @service.report.open_holds(order_id: 'order').first[:remaining]
    assert_equal ['A'], @service.report.low_stock(20).map { |r| r[:sku] }
  end

  def test_importer_validates_all_rows_before_receiving
    importer = Inventory::Importer.new(@service)
    assert_raises(Inventory::InvalidInput) { importer.receipts("sku,quantity\nB,2\nC,no\n", at: @start) }
    assert_equal 0, @service.stock('B', at: @start)[:on_hand]
    assert_equal 2, importer.receipts("sku,quantity\nB,2\nC,3\n", at: @start)
    assert_equal 3, @service.stock('C', at: @start)[:available]
  end
end
