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
      def initialize(cluster:, instance_family_weights: {}, availability_zone_weights: {}, weights: {}, partition_weights: {})
        @cluster = cluster
        @instance_family_weights = instance_family_weights
        @availability_zone_weights = availability_zone_weights
        @weights = weights
        @partition_weights = partition_weights
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
        member_id_to_instance_id = {}

        instance_family_to_capacity = @instance_family_weights.is_a?(Proc) ? @instance_family_weights.call() : @instance_family_weights
        az_to_capacity = @availability_zone_weights.is_a?(Proc) ? @availability_zone_weights.call() : @availability_zone_weights
        weights = @weights.is_a?(Proc) ? @weights.call() : @weights
        members.each do |member_id|
          group_assignment[member_id] = Protocol::MemberAssignment.new

          instance_id, instance_type, az = member_id_to_metadata[member_id].split(",")
          instance_id_to_member_ids[instance_id] << member_id
          member_id_to_instance_id[member_id] = instance_id
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

        partition_weights = build_partition_weights(topics)
        partition_weight_per_capacity = topic_partitions.sum { |topic, partition| partition_weights.dig(topic, partition) } / total_capacity

        last_index = 0
        member_id_to_acceptable_partition_weight = {}
        instance_id_to_total_acceptable_partition_weight = Hash.new(0)
        instance_id_to_capacity.each do |instance_id, capacity|
          member_ids = instance_id_to_member_ids[instance_id]
          member_ids.each do |member_id|
            acceptable_partition_weight = capacity * partition_weight_per_capacity / member_ids.size
            while last_index < topic_partitions.size
              topic, partition = topic_partitions[last_index]
              partition_weight = partition_weights.dig(topic, partition)
              break if acceptable_partition_weight - partition_weight < 0

              group_assignment[member_id].assign(topic, [partition])
              acceptable_partition_weight -= partition_weight

              last_index += 1
            end

            member_id_to_acceptable_partition_weight[member_id] = acceptable_partition_weight
            instance_id_to_total_acceptable_partition_weight[instance_id] += acceptable_partition_weight
          end
        end

        while last_index < topic_partitions.size
          max_acceptable_partition_weight = member_id_to_acceptable_partition_weight.values.max
          member_ids = member_id_to_acceptable_partition_weight.select { |_, w| w == max_acceptable_partition_weight }.keys
          if member_ids.size == 1
            member_id = member_ids.first
          else
            member_id =  member_ids.max_by { |id| instance_id_to_total_acceptable_partition_weight[member_id_to_instance_id[id]] }
          end
          topic, partition = topic_partitions[last_index]
          group_assignment[member_id].assign(topic, [partition])

          partition_weight = partition_weights.dig(topic, partition)
          member_id_to_acceptable_partition_weight[member_id] -= partition_weight
          instance_id_to_total_acceptable_partition_weight[member_id_to_instance_id[member_id]] -= partition_weight

          last_index += 1
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
        (capacity || instance_family_to_capacity.fetch(instance_family, 1) * az_to_capacity.fetch(az, 1)).to_f
      end

      def build_partition_weights(topics)
        # Duplicate the weights to not destruct @partition_weights or the return value of @partition_weights
        weights = (@partition_weights.is_a?(Proc) ? @partition_weights.call() : @partition_weights).dup
        topics.each do |t|
          weights[t] = weights[t].dup || {}
          weights[t].default = 1
        end

        weights
      end
    end
  end
end
