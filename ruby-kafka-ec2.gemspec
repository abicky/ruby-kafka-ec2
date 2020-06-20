require_relative 'lib/kafka/ec2/version'

Gem::Specification.new do |spec|
  spec.name          = "ruby-kafka-ec2"
  spec.version       = Kafka::EC2::VERSION
  spec.authors       = ["abicky"]
  spec.email         = ["takeshi.arabiki@gmail.com"]

  spec.summary       = %q{An extension of ruby-kafka for EC2}
  spec.description   = %q{Kafka::EC2 is an extension of ruby-kafka that provides useful features for EC2 like Kafka::EC2::MixedInstanceAssignmentStrategy.}
  spec.homepage      = "https://github.com/abicky/ruby-kafka-ec2"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.3.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "ruby-kafka", ">= 0.7", "< 2"

  spec.add_development_dependency "webmock"
  spec.add_development_dependency "concurrent-ruby" # cf. https://github.com/zendesk/ruby-kafka/pull/835
end
