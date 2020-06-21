require "json"
require "time"

require "concurrent"
require "kafka"
require "mysql2"

KAFKA_BROKERS = ENV.fetch("KAFKA_BROKERS", "localhost:9092").split(/\p{Space}*,\p{Space}*/)
KAFKA_CLIENT_ID = "net.abicky.ruby-kafka-ec2"
KAFKA_TOPIC = ENV.fetch("KAFKA_TOPIC") do
  raise 'The environment variable "KAFKA_TOPIC" must be specified'
end
PARTITION_COUNT = 200
MAX_BUFFER_SIZE = 1_000
MESSAGE_COUNT = 1_000_000

$stdout.sync = true
logger = Logger.new($stdout)

client = Mysql2::Client.new(
  host: ENV["MYSQL_HOST"] || "localhost",
  port: 3306,
  username: "admin",
  password: ENV["MYSQL_PASSWORD"],
)
client.query("CREATE DATABASE IF NOT EXISTS ruby_kafka_ec2_benchmark")
client.query(<<~SQL)
  CREATE TABLE IF NOT EXISTS ruby_kafka_ec2_benchmark.events (
    id bigint(20) NOT NULL AUTO_INCREMENT,
    name varchar(255) NOT NULL,
    created_at datetime NOT NULL,
    PRIMARY KEY (id)
  )
SQL
client.query(<<~SQL)
  INSERT INTO ruby_kafka_ec2_benchmark.events (name, created_at) VALUES ('page_view', '#{Time.now.strftime("%F %T")}')
SQL

kafka = Kafka.new(KAFKA_BROKERS, client_id: KAFKA_CLIENT_ID)

unless kafka.topics.include?(KAFKA_TOPIC)
  logger.info "Create the kafka topic '#{KAFKA_TOPIC}'"
  kafka.create_topic(KAFKA_TOPIC, num_partitions: PARTITION_COUNT, replication_factor: 3)
end

now = Time.now.iso8601(3)
message = {
  events: [{ name: "page_view", timestamp: now }] * 10,
}.to_json


logger.info "Producing messages..."

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pool = Concurrent::FixedThreadPool.new(4)
producers = {}
current_processed_count = Concurrent::AtomicFixnum.new
futures = []
MESSAGE_COUNT.times do |i|
  futures << Concurrent::Future.execute(executor: pool) do
    producers[Thread.current.object_id] ||= kafka.producer(max_buffer_size: MAX_BUFFER_SIZE)
    producer = producers[Thread.current.object_id]
    producer.produce(message,
      topic: KAFKA_TOPIC,
      key: i.to_s,
      partition: i % PARTITION_COUNT,
    )
    if producer.buffer_size == MAX_BUFFER_SIZE
      producer.deliver_messages
    end
    processed_count = current_processed_count.increment
    logger.info "#{processed_count} messages were produced" if (processed_count % 10_000).zero?
  end

  if futures.size == 10_000
    futures.each(&:wait!)
    futures.clear
  end
end
futures.each(&:wait!)

producers.each_value(&:deliver_messages)

logger.info "Produce FIN messages"
producer = kafka.producer
PARTITION_COUNT.times do |i|
  producer.produce("FIN",
    topic: KAFKA_TOPIC,
    key: "fin_#{i}",
    partition: i % PARTITION_COUNT,
  )
end
producer.deliver_messages

duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
logger.info "Complete (duration: #{duration})"
