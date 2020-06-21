FROM ruby:2.7

WORKDIR /work

COPY Gemfile ruby-kafka-ec2.gemspec /tmp/ruby-kafka-ec2/
COPY lib /tmp/ruby-kafka-ec2/lib/

COPY benchmark/Gemfile /work/
RUN bundle install -j4

COPY benchmark/produce_messages.rb benchmark/consume_messages.rb /work/

ENTRYPOINT ["bundle", "exec", "ruby"]
