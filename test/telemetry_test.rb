# frozen_string_literal: true

require "minitest/autorun"
require "cleave"

class TelemetryTest < Minitest::Test
  def test_duration_does_not_claim_precision_below_clock_resolution
    assert_equal "unavailable", Cleave::Telemetry.duration(nil)
    assert_equal "below clock resolution", Cleave::Telemetry.duration(0)
    assert_equal "<0.001 ms", Cleave::Telemetry.duration(1)
    assert_equal "1.000 ms", Cleave::Telemetry.duration(1_000_000)
  end

  def test_unavailable_and_partial_values_are_not_presented_as_complete
    state = { "telemetry" => Cleave::Telemetry.initial, "example_count" => 0, "reports_complete" => false,
              "verification" => { "status" => "incomplete" } }
    text = Cleave::Telemetry.render(state)
    assert_includes text, "partial reports"
    assert_includes text, "Worker collection elapsed: unavailable"
    assert_includes text, "Discovered spec files: unavailable"
    assert_includes text, "Diagnostic candidate: unavailable (incomplete)"
    refute_match(/time saved|tests skipped|false.negative rate/i, text)
  end
end
