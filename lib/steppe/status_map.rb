# frozen_string_literal: true

module Steppe
  class StatusMap
    def initialize
      @responders = []
      @index = nil
    end

    def <<(responder)
      @responders << responder
      build_index
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

    private

    def build_index
      # Collect all boundary points with priorities
      points = []
      @responders.each_with_index do |responder, index|
        range = responder.statuses
        # Add index as priority - earlier additions have higher priority
        points << [range.begin, :start, index, responder]
        points << [range.end + 1, :end, index, responder]
      end
      # Sort by position, then by type (:end before :start at same position),
      # then by priority (lower index first)
      points.sort_by! { |pos, type, priority, _| [pos, type == :start ? 1 : 0, priority] }

      # Build non-overlapping segments
      segments = []
      active = {} # Map from responder to priority
      prev_point = nil

      points.each do |point, type, priority, responder|
        # If we have active responders and moved to a new point, create segment
        if !active.empty? && prev_point && prev_point < point
          # Use the highest priority responder (min priority value = first added)
          winner = active.min_by { |_, p| p }.first
          segments << [prev_point, point - 1, winner]
        end

        if type == :start
          active[responder] = priority
        else
          active.delete(responder)
        end

        prev_point = point
      end

      @index = segments
    end
  end
end
