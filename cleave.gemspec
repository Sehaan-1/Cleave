# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "cleave-ste"
  spec.version = "0.1.0"
  spec.summary = "Static dependency facts for selective test execution"
  spec.authors = ["Cleave contributors"]
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "prism", ">= 1.2", "< 2.0"
  spec.add_dependency "sorbet-runtime", "~> 0.5"
  spec.add_development_dependency "minitest", ">= 5.0", "< 6.0"
end
