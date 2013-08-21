# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
Gem::Specification.new do |spec|
  spec.name          = "bosh"
  spec.version       = '0.2.1'
  spec.authors       = ["Genki Takiuchi"]
  spec.email         = ["genki@s21g.com"]
  spec.description   = <<-EOD
    It can automatically reconnect to the host with the remote GNU screen
    session.
  EOD
  spec.summary       = %q{Bosh is fake mosh}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
end
