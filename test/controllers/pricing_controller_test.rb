require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  # --- Happy path ---

  test "returns rate for valid parameters" do
    RateApiClient.stub(:get_rates, rates_response('Summer', 'FloatingPointResort', 'SingletonRoom', '15000')) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :success
    assert_equal "application/json", @response.media_type
    assert_equal 15000, JSON.parse(@response.body)["rate"]
  end

  test "normalizes rate to integer when API returns a string" do
    RateApiClient.stub(:get_rates, rates_response('Summer', 'FloatingPointResort', 'SingletonRoom', '15000')) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :success
    assert_kind_of Integer, JSON.parse(@response.body)["rate"]
  end

  # --- Caching ---

  test "returns cached rate without calling the API on cache hit" do
    Rails.cache.write("pricing/Summer/FloatingPointResort/SingletonRoom", 99999)

    RateApiClient.stub(:get_rates, ->(_) { flunk "API should not be called on cache hit" }) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :success
    assert_equal 99999, JSON.parse(@response.body)["rate"]
  end

  test "calls the API only once for repeated requests to the same combination" do
    call_count = 0
    mock = ->(_) { call_count += 1; rates_response('Summer', 'FloatingPointResort', 'SingletonRoom', '15000') }

    RateApiClient.stub(:get_rates, mock) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_equal 1, call_count
  end

  # --- Error handling ---

  test "returns 502 when rate API returns an error" do
    error_response = OpenStruct.new(success?: false, body: { 'error' => 'upstream failure' }.to_json)

    RateApiClient.stub(:get_rates, error_response) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :bad_gateway
    assert_includes JSON.parse(@response.body)["error"], "upstream failure"
  end

  test "returns 503 when rate API times out" do
    RateApiClient.stub(:get_rates, ->(_) { raise Net::ReadTimeout }) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :service_unavailable
    assert_includes JSON.parse(@response.body)["error"], "timed out"
  end

  test "returns 502 when rate is missing from API response" do
    empty_response = OpenStruct.new(success?: true, body: { 'rates' => [] }.to_json)

    RateApiClient.stub(:get_rates, empty_response) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :bad_gateway
  end

  # --- Input validation ---

  test "returns 400 without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "returns 400 for empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "returns 400 for invalid period" do
    get api_v1_pricing_url, params: { period: "InvalidSeason", hotel: "FloatingPointResort", room: "SingletonRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid period"
  end

  test "returns 400 for invalid hotel" do
    get api_v1_pricing_url, params: { period: "Summer", hotel: "InvalidHotel", room: "SingletonRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid hotel"
  end

  test "returns 400 for invalid room" do
    get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "InvalidRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid room"
  end

  private

  def rates_response(period, hotel, room, rate)
    body = { 'rates' => [{ 'period' => period, 'hotel' => hotel, 'room' => room, 'rate' => rate }] }.to_json
    OpenStruct.new(success?: true, body: body)
  end
end
