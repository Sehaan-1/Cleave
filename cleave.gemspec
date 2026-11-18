# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "cleave-ste"
  spec.version = "0.1.0"
  spec.summary = "Dependency analysis and scoped observations for selective test execution"
  spec.authors = ["Cleave contributors"]
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "lib/cleave/graph_template.html", "exe/*", "LICENSE", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["cleave"]
  spec.require_paths = ["lib"]
  spec.add_dependency "prism", ">= 1.2", "< 2.0"
  spec.add_dependency "sorbet-runtime", "~> 0.5"
  spec.add_development_dependency "minitest", ">= 5.0", "< 6.0"
  spec.add_development_dependency "rspec", "~> 3.13"
end
