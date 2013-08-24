# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require File.join(lib, %w[rosh version])
Gem::Specification.new do |spec|
  spec.name          = "rosh"
  spec.version       = Rosh::VERSION
  spec.authors       = ["Genki Takiuchi"]
  spec.email         = ["genki@s21g.com"]
  spec.description   = <<-EOD
    It can automatically reconnect to the host with the remote GNU screen
    session.
  EOD
  spec.summary       = %q{Rosh is roaming shell}
  spec.homepage      = 'https://github.com/genki/rosh'
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
end
