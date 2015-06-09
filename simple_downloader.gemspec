# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'simple_downloader/version'

Gem::Specification.new do |spec|
  spec.name          = "simple_downloader"
  spec.version       = SimpleDownloader::VERSION
  spec.authors       = ["yuri-karpovich"]
  spec.email         = ["spoonest@gmail.com"]

  spec.summary       = "Download, Upload files from SFTP"
  spec.description   = "This gem is not ready for use. Please do not install it."
  spec.homepage      = "https://github.com/yuri-karpovich/simple_downloader"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]


  spec.add_development_dependency "bundler", "~> 1.8"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", '~> 3.2', '>= 3.2.0'
  spec.add_development_dependency "yard", '~> 0.8.7', '>= 0.8.7.6'
  spec.add_dependency "net-sftp", '~> 2.1', '>= 2.1.2'
  spec.add_dependency "retryable", '~> 2.0', '>= 2.0.1'
  spec.add_dependency "activesupport", '>= 4.1'

end
