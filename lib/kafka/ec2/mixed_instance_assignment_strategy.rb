# frozen_string_literal: true

require "kafka"
require "kafka/protocol/member_assignment"

module Kafka
  class EC2
    class MixedInstanceAssignmentStrategy
      # metadata is a byte sequence created by Kafka::Protocol::ConsumerGroupProtocol.encode
      attr_accessor :member_id_to_metadata

      # @param cluster [Kafka::Cluster]
      # @param instance_family_weights [Hash{String => Numeric}, Proc] a hash whose the key
      #   is the instance family and whose value is the weight. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      # @param availability_zone_weights [Hash{String => Numeric}, Proc] a hash whose the key
      #   is the availability zone and whose value is the weight. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      # @param weights [Hash{String => Hash{String => Numeric}}, Proc] a hash whose the key
      #   is the availability zone or the instance family and whose value is the hash like
      #   instance_family_weights or availability_zone_weights. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      def initialize(cluster:, instance_family_weights: {}, availability_zone_weights: {}, weights: {})
        @cluster = cluster
        @instance_family_weights = instance_family_weights
        @availability_zone_weights = availability_zone_weights
        @weights = weights
      end

      # Assign the topic partitions to the group members.
      #
      # @param members [Array<String>] member ids
      # @param topics [Array<String>] topics
      # @return [Hash{String => Protocol::MemberAssignment}] a hash mapping member
      #   ids to assignments.
      def assign(members:, topics:)
        group_assignment = {}
        instance_id_to_capacity = Hash.new(0)
        instance_id_to_member_ids = Hash.new { |h, k| h[k] = [] }
        total_capacity = 0

        instance_family_to_capacity = @instance_family_weights.is_a?(Proc) ? @instance_family_weights.call() : @instance_family_weights
        az_to_capacity = @availability_zone_weights.is_a?(Proc) ? @availability_zone_weights.call() : @availability_zone_weights
        weights = @weights.is_a?(Proc) ? @weights.call() : @weights
        members.each do |member_id|
          group_assignment[member_id] = Protocol::MemberAssignment.new

          instance_id, instance_type, az = member_id_to_metadata[member_id].split(",")
          instance_id_to_member_ids[instance_id] << member_id
          capacity = calculate_capacity(instance_type, az, instance_family_to_capacity, az_to_capacity, weights)
          instance_id_to_capacity[instance_id] += capacity
          total_capacity += capacity
        end

        topic_partitions = topics.flat_map do |topic|
          begin
            partitions = @cluster.partitions_for(topic).map(&:partition_id)
          rescue UnknownTopicOrPartition
            raise UnknownTopicOrPartition, "unknown topic #{topic}"
          end
          Array.new(partitions.count) { topic }.zip(partitions)
        end

        partition_count_per_capacity = topic_partitions.size / total_capacity
        last_index = 0
        instance_id_to_capacity.sort_by { |_, capacity| -capacity }.each do |instance_id, capacity|
          partition_count = (capacity * partition_count_per_capacity).round
          member_ids = instance_id_to_member_ids[instance_id]
          topic_partitions[last_index, partition_count]&.each_with_index do |(topic, partition), index|
            member_id = member_ids[index % member_ids.size]
            group_assignment[member_id].assign(topic, [partition])
          end

          last_index += partition_count
        end

        if last_index < topic_partitions.size
          member_ids = instance_id_to_member_ids.values.flatten
          topic_partitions[last_index, topic_partitions.size].each_with_index do |(topic, partition), index|
            member_id = member_ids[index % member_ids.size]
            group_assignment[member_id].assign(topic, [partition])
          end
        end

        group_assignment
      rescue Kafka::LeaderNotAvailable
        sleep 1
        retry
      end

      private

      def calculate_capacity(instance_type, az, instance_family_to_capacity, az_to_capacity, weights)
        instance_family, _ = instance_type.split(".")

        capacity = weights.dig(az, instance_family) || weights.dig(instance_family, az)
        capacity || instance_family_to_capacity.fetch(instance_family, 1) * az_to_capacity.fetch(az, 1)
      end
    end
  end
end
