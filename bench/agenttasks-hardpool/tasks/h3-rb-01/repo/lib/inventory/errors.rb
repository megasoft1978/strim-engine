module Inventory
  class Error < StandardError; end
  class InvalidInput < Error; end
  class NotFound < Error; end
  class Conflict < Error; end
  class InsufficientStock < Error; end
end
