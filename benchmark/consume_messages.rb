require "json"
require "net/http"
require "time"

require "kafka"
require "concurrent/map" # cf. https://github.com/zendesk/ruby-kafka/pull/835
require "mysql2"

KAFKA_BROKERS = ENV.fetch("KAFKA_BROKERS", "localhost:9092").split(/\p{Space}*,\p{Space}*/)
KAFKA_CLIENT_ID = "net.abicky.ruby-kafka-ec2"
KAFKA_CONSUMER_GROUP_ID = "net.abicky.ruby-kafka-ec2.benchmark"
KAFKA_TOPIC = ENV.fetch("KAFKA_TOPIC") do
  raise 'The environment variable "KAFKA_TOPIC" must be specified'
end

$stdout.sync = true
logger = Logger.new($stdout)

kafka = Kafka.new(KAFKA_BROKERS, client_id: KAFKA_CLIENT_ID)
if ENV["USE_KAFKA_EC2"] == "true"
  logger.info "Use ruby-kafka-ec2"
  require "aws-sdk-rds"
  require "kafka/ec2"

  rds = Aws::RDS::Client.new(region: "ap-northeast-1")
  assignment_strategy_factory = Kafka::EC2::MixedInstanceAssignmentStrategyFactory.new(
    instance_family_weights: {
      "r4" => 1.00,
      "r5" => 1.20,
      "m5" => 1.35,
    },
    availability_zone_weights: ->() {
      db_cluster = rds.describe_db_clusters(filters: [
        { name: "db-cluster-id", values: ["ruby-kafka-ec2-benchmark"] },
      ]).db_clusters.first
      db_instance_id = db_cluster.db_cluster_members.find { |m| m.is_cluster_writer }.db_instance_identifier
      db_instance = rds.describe_db_instances(filters: [
        { name: "db-cluster-id", values: ["ruby-kafka-ec2-benchmark"] },
        { name: "db-instance-id", values: [db_instance_id] },
      ]).db_instances.first

      if db_instance.availability_zone == "ap-northeast-1a"
        {
          "ap-northeast-1a" => 1,
          "ap-northeast-1c" => 0.25,
        }
      else
        {
          "ap-northeast-1a" => 0.25,
          "ap-northeast-1c" => 1,
        }
      end
    },
  )
  consumer = Kafka::EC2.with_assignment_strategy_factory(assignment_strategy_factory) do
    kafka.consumer(group_id: KAFKA_CONSUMER_GROUP_ID)
  end
else
  logger.info "Use ruby-kafka"
  consumer = kafka.consumer(group_id: KAFKA_CONSUMER_GROUP_ID)
end

consumer.subscribe(KAFKA_TOPIC)

trap(:TERM) { consumer.stop }

metadata = Net::HTTP.start("169.254.169.254", 80) do |http|
  {
    instance_id: http.get("/latest/meta-data/instance-id").body,
    instance_type: http.get("/latest/meta-data/instance-type").body,
    availability_zone: http.get("/latest/meta-data/placement/availability-zone").body,
  }
end

client = Mysql2::Client.new(
  host: ENV["MYSQL_HOST"] || "localhost",
  port: 3306,
  username: "admin",
  password: ENV["MYSQL_PASSWORD"],
)

logger.info "[#{metadata}] Consuming messages..."

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
processed_count = 0
partition_count = 0
end_time = nil
consumer.each_message do |message|
  if message.value == "FIN"
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    partition_count += 1
    logger.info "[#{metadata}] Received FIN message"
    next
  end

  JSON.parse(message.value)["events"].each do |event|
    Time.iso8601(event["timestamp"])
  end
  client.query("SELECT * FROM ruby_kafka_ec2_benchmark.events").to_a

  processed_count += 1
  logger.info "[#{metadata}] #{processed_count} messages were consumed" if (processed_count % 10_000).zero?
end

duration = end_time - start_time
logger.info "[#{metadata}] Complete (duration: #{duration}, partition_count: #{partition_count}, processed_count: #{processed_count})"
