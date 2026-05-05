require "spec"
require "../src/karma"

Karma.configure { |c| c.log = false }

Spec.before_each do
  Karma::Ingest.reset!
  Karma::Recovery.reset!
end

def parse_response(response : String) : JSON::Any
  JSON.parse(response)
end

def expect_success(response : String) : JSON::Any
  parsed = parse_response(response)
  parsed["protocol_version"].as_i.should eq(Karma::Protocol::VERSION)
  parsed["success"].as_bool.should be_true
  parsed["error_code"].raw.should be_nil
  parsed
end

def expect_error(response : String, code : String) : JSON::Any
  parsed = parse_response(response)
  parsed["protocol_version"].as_i.should eq(Karma::Protocol::VERSION)
  parsed["success"].as_bool.should be_false
  parsed["error_code"].as_s.should eq(code)
  parsed
end
