# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

require_relative '../../../../../lib/opentelemetry/instrumentation/bunny'
require_relative '../../../../../lib/opentelemetry/instrumentation/bunny/patch_helpers'
require_relative '../../../../../lib/opentelemetry/instrumentation/bunny/patches/queue'

describe OpenTelemetry::Instrumentation::Bunny::Patches::Queue do
  let(:instrumentation) { OpenTelemetry::Instrumentation::Bunny::Instrumentation.instance }
  let(:config) { {} }
  let(:exporter) { EXPORTER }
  let(:spans) { exporter.finished_spans }

  let(:host) { ENV.fetch('TEST_RABBITMQ_HOST', 'localhost') }
  let(:port) { ENV.fetch('TEST_RABBITMQ_PORT', '5672') }
  let(:url) { ENV.fetch('TEST_RABBITMQ_URL') { "amqp://guest:guest@#{host}:#{port}" } }
  let(:bunny) { Bunny.new(url) }
  let(:topic) { "topic-#{SecureRandom.uuid}" }
  let(:channel) { bunny.create_channel }
  let(:queue_name) { "opentelemetry-ruby-#{SecureRandom.uuid}" }
  let(:queue) { channel.queue(queue_name) }

  before do
    bunny.start

    # Clear spans
    exporter.reset

    instrumentation.install(config)
  end

  after do
    # Force re-install of instrumentation
    instrumentation.instance_variable_set(:@installed, false)

    # Clean up
    bunny.close
  end

  describe 'pop' do
    it 'traces messages handled in a block' do
      queue.publish('Hello, opentelemetry!')

      queue.pop { |_delivery_info, _metadata, _payload| break }

      send_span = spans.find { |span| span.name == ".#{queue_name} send" }
      _(send_span).wont_be_nil

      receive_span = spans.find { |span| span.name == ".#{queue_name} receive" }
      _(receive_span).wont_be_nil

      process_span = spans.find { |span| span.name == ".#{queue_name} process" }
      _(process_span).wont_be_nil
      _(process_span.kind).must_equal(:consumer)

      linked_span_context = process_span.links.first.span_context
      _(linked_span_context.trace_id).must_equal(send_span.trace_id)
    end

    it 'traces messages returned' do
      queue.publish('Hello, opentelemetry!')

      queue.pop

      receive_span = spans.find { |span| span.name == ".#{queue_name} receive" }
      _(receive_span).wont_be_nil

      process_span = spans.find { |span| span.name == ".#{queue_name} process" }
      _(process_span).must_be_nil
    end

    describe 'when propagation_style is child' do
      let(:config) { { propagation_style: :child } }

      it 'maintains a continuous trace' do
        queue.publish('Hello, opentelemetry!')

        queue.pop { |_delivery_info, _metadata, _payload| break }

        send_span = spans.find { |span| span.name == ".#{queue_name} send" }
        receive_span = spans.find { |span| span.name == ".#{queue_name} receive" }
        process_span = spans.find { |span| span.name == ".#{queue_name} process" }


        _(receive_span.parent_span_id).must_equal(send_span.span_id) # fails; is INVALID_SPAN_ID
        _(receive_span.trace_id).must_equal(send_span.trace_id) # fails.

        _(process_span.parent_span_id).must_equal(receive_span.span_id) # fails; is send_span.span_id
        _(process_span.trace_id).must_equal(send_span.trace_id) # succeeds
      end

      it 'propagates baggage' do
        ctx = OpenTelemetry::Baggage.set_value('testing_baggage', 'it_worked')

        OpenTelemetry::Context.with_current(ctx) do
          queue.publish('Hello, opentelemetry!')
        end

        queue.pop do |_delivery_info, _metadata, _payload|
          _(OpenTelemetry::Baggage.value('testing_baggage')).must_equal('it_worked')
        end
      end
    end
  end
end unless ENV['OMIT_SERVICES']
