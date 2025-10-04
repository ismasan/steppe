# frozen_string_literal: true

module Steppe
  class StatusMap
    def initialize
      @index = []
    end

    def <<(responder)
      range = responder.statuses

      start = range.begin
      finish = range.end

      # Binary search to find insertion point
      lo = 0
      hi = @index.size - 1
      insert_at = @index.size

      while lo <= hi
        mid = (lo + hi) / 2
        s, _, _ = @index[mid]
        if start < s
          insert_at = mid
          hi = mid - 1
        else
          lo = mid + 1
        end
      end

      # Check overlap with previous range
      if insert_at > 0
        prev_start, prev_end, _ = @index[insert_at - 1]
        if start <= prev_end
          raise ArgumentError, "Responder range #{range} overlaps with #{prev_start}..#{prev_end}"
        end
      end

      # Check overlap with next range
      if insert_at < @index.size
        next_start, next_end, _ = @index[insert_at]
        if finish >= next_start
          raise ArgumentError, "Responder range #{range} overlaps with #{next_start}..#{next_end}"
        end
      end

      # Insert responder
      @index.insert(insert_at, [start, finish, responder])
      self
    end

    def find(status)
      lo = 0
      hi = @index.size - 1

      while lo <= hi
        mid = (lo + hi) / 2
        start, finish, responder = @index[mid]

        if status < start
          hi = mid - 1
        elsif status > finish
          lo = mid + 1
        else
          return responder
        end
      end

      nil
    end
  end
end
