require "kafka/ec2/ext/consumer_group"
require "kafka/ec2/ext/protocol/join_group_request"
require "kafka/ec2/mixed_instance_assignment_strategy_factory"
require "kafka/ec2/version"

module Kafka
  class EC2
    class << self
      attr_reader :assignment_strategy_factory

      def with_assignment_strategy_factory(factory)
        @assignment_strategy_factory = factory
        yield
      ensure
        @assignment_strategy_factory = nil
      end

      def assignment_strategy_classes
        @assignment_strategy_classes ||= {}
      end
    end
  end
end
