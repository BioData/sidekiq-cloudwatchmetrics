# Sidekiq CloudWatch Metrics

Runs a thread inside your Sidekiq processes to report metrics to CloudWatch
useful for autoscaling and keeping an eye on your queues.

Optimised for Sidekiq Enterprise with leader election, but works everywhere!

## Installation

Add this gem to your application’s Gemfile near sidekiq and then run `bundle install`:

```ruby
gem "sidekiq"
gem "sidekiq-cloudwatchmetrics"
```

## Usage

Add near your Sidekiq configuration, like in `config/initializers/sidekiq.rb` in Rails:

```ruby
require "sidekiq"
require "sidekiq/cloudwatchmetrics"

Sidekiq::CloudWatchMetrics.enable!
```

By default this assumes you're running on an EC2 instance with an instance role
that can publish CloudWatch metrics, or that you've supplied AWS credentials
through environment variables that aws-sdk expects. You can also explicitly
supply an [aws-sdk CloudWatch Client instance][cwclient]:

```ruby
Sidekiq::CloudWatchMetrics.enable!(client: AWS::CloudWatch::Client.new)
```

  [cwclient]: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/CloudWatch/Client.html

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sj26/sidekiq-cloudwatchmetrics.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

