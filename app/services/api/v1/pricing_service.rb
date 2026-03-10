module Api::V1
  class PricingService < BaseService
    attr_reader :error_status

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

      if response.success?
        parsed = JSON.parse(response.body)
        rate = parsed['rates']&.detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }

        if rate.nil?
          @error_status = :bad_gateway
          errors << 'Rate not found in upstream response'
        else
          @result = rate['rate'].to_i
        end
      else
        @error_status = :bad_gateway
        parsed_error = JSON.parse(response.body) rescue {}
        errors << (parsed_error['error'] || 'Rate API returned an error')
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      @error_status = :service_unavailable
      errors << 'Rate API timed out'
    rescue => e
      @error_status = :bad_gateway
      errors << 'Unexpected error fetching rate'
    end
  end
end
