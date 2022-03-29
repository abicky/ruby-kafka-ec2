require "spec_helper"

RSpec.describe Kafka::EC2 do
  it "has a version number" do
    expect(Kafka::EC2::VERSION).not_to be nil
  end
end
