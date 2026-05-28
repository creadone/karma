# frozen_string_literal: true

require_relative "lib/karma_client/version"

Gem::Specification.new do |spec|
  spec.name = "karma_client"
  spec.version = KarmaClient::VERSION
  spec.authors = ["Sergey Fedorov"]
  spec.email = ["creadone@gmail.com"]

  spec.summary = "Ruby and Ruby on Rails client for the Karma hot counter database"
  spec.description = "A small TCP JSON v2 client for Karma with timeouts, Rails configuration, pooling, and typed errors."
  spec.homepage = "https://github.com/creadone/karma"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
end
