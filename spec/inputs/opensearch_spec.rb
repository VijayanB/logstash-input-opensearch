# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/devutils/rspec/shared_examples"
require "logstash/inputs/opensearch"
require "opensearch"
require "timecop"
require "stud/temporary"
require "time"
require "date"
require "cabin"
require "webrick"
require "uri"

require 'logstash/plugin_mixins/ecs_compatibility_support/spec_helper'

describe LogStash::Inputs::OpenSearch, :ecs_compatibility_support do

  let(:plugin) { described_class.new(config) }
  let(:queue) { Queue.new }

  before(:each) do
     OpenSearch::Client.send(:define_method, :ping) { } # define no-action ping method
  end

  context "register" do
    let(:config) do
      {
        "schedule" => "* * * * * UTC"
      }
    end

    context "against authentic OpenSearch" do
      it "should not raise an exception" do
       expect { plugin.register }.to_not raise_error
     end
    end

    context "against not authentic OpenSearch" do
      before(:each) do
         OpenSearch::Client.send(:define_method, :ping) { raise OpenSearch::UnsupportedProductError.new("Fake error") } # define error ping method
      end

      it "should raise ConfigurationError" do
        expect { plugin.register }.to raise_error(LogStash::ConfigurationError)
      end
    end
  end

  it_behaves_like "an interruptible input plugin" do
    let(:client) { double("opensearch-client") }
    let(:config) do
      {
        "schedule" => "* * * * * UTC"
      }
    end

    before :each do
      allow(OpenSearch::Client).to receive(:new).and_return(client)
      hit = {
        "_index" => "logstash-2014.10.12",
        "_type" => "logs",
        "_id" => "C5b2xLQwTZa76jBmHIbwHQ",
        "_score" => 1.0,
        "_source" => { "message" => ["ohayo"] }
      }
      allow(client).to receive(:search) { { "hits" => { "hits" => [hit] } } }
      allow(client).to receive(:scroll) { { "hits" => { "hits" => [hit] } } }
      allow(client).to receive(:clear_scroll).and_return(nil)
      allow(client).to receive(:ping)
    end
  end


  ecs_compatibility_matrix(:disabled, :v1, :v8) do |ecs_select|

    before(:each) do
      allow_any_instance_of(described_class).to receive(:ecs_compatibility).and_return(ecs_compatibility)
    end

    let(:config) do
      %q[
        input {
          opensearch {
            hosts => ["localhost"]
            query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
          }
        }
      ]
    end

    let(:mock_response) do
      {
          "_scroll_id" => "cXVlcnlUaGVuRmV0Y2g",
          "took" => 27,
          "timed_out" => false,
          "_shards" => {
              "total" => 169,
              "successful" => 169,
              "failed" => 0
          },
          "hits" => {
              "total" => 1,
              "max_score" => 1.0,
              "hits" => [ {
                              "_index" => "logstash-2014.10.12",
                              "_type" => "logs",
                              "_id" => "C5b2xLQwTZa76jBmHIbwHQ",
                              "_score" => 1.0,
                              "_source" => { "message" => ["ohayo"] }
                          } ]
          }
      }
    end

    let(:mock_scroll_response) do
      {
          "_scroll_id" => "r453Wc1jh0caLJhSDg",
          "hits" => { "hits" => [] }
      }
    end

    before(:each) do
      client = OpenSearch::Client.new
      expect(OpenSearch::Client).to receive(:new).with(any_args).and_return(client)
      expect(client).to receive(:search).with(any_args).and_return(mock_response)
      expect(client).to receive(:scroll).with({ :body => { :scroll_id => "cXVlcnlUaGVuRmV0Y2g" }, :scroll=> "1m" }).and_return(mock_scroll_response)
      expect(client).to receive(:clear_scroll).and_return(nil)
      expect(client).to receive(:ping)
    end

    it 'creates the events from the hits' do
      event = input(config) do |pipeline, queue|
        queue.pop
      end

      expect(event).to be_a(LogStash::Event)
      expect(event.get("message")).to eql [ "ohayo" ]
    end

    context 'when a target is set' do
      let(:config) do
        %q[
          input {
            opensearch {
              hosts => ["localhost"]
              query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
              target => "[@metadata][_source]"
            }
          }
        ]
      end

      it 'creates the event using the target' do
        event = input(config) do |pipeline, queue|
          queue.pop
        end

        expect(event).to be_a(LogStash::Event)
        expect(event.get("[@metadata][_source][message]")).to eql [ "ohayo" ]
      end
    end

  end

  # This spec is an adapter-spec, ensuring that we send the right sequence of messages to our OpenSearch Client
  # to support sliced scrolling. The underlying implementation will spawn its own threads to consume, so we must be
  # careful to use thread-safe constructs.
  context "with managed sliced scrolling" do
    let(:config) do
      {
          'query' => "#{LogStash::Json.dump(query)}",
          'slices' => slices,
          'docinfo' => true, # include ids
          'docinfo_target' => '[@metadata]'
      }
    end
    let(:query) do
      {
        "query" => {
          "match" => { "city_name" => "Okinawa" }
        },
        "fields" => ["message"]
      }
    end
    let(:slices) { 2 }

    context 'with `slices => 0`' do
      let(:slices) { 0 }
      it 'fails to register' do
        expect { plugin.register }.to raise_error(LogStash::ConfigurationError)
      end
    end

    context 'with `slices => 1`' do
      let(:slices) { 1 }
      it 'runs just one slice' do
        expect(plugin).to receive(:do_run_slice).with(duck_type(:<<))
        expect(Thread).to_not receive(:new)

        plugin.register
        plugin.run([])
      end
    end

    context 'without slices directive' do
      let(:config) { super().tap { |h| h.delete('slices') } }
      it 'runs just one slice' do
        expect(plugin).to receive(:do_run_slice).with(duck_type(:<<))
        expect(Thread).to_not receive(:new)

        plugin.register
        plugin.run([])
      end
    end

    2.upto(8) do |slice_count|
      context "with `slices => #{slice_count}`" do
        let(:slices) { slice_count }
        it "runs #{slice_count} independent slices" do
          expect(Thread).to receive(:new).and_call_original.exactly(slice_count).times
          slice_count.times do |slice_id|
            expect(plugin).to receive(:do_run_slice).with(duck_type(:<<), slice_id)
          end

          plugin.register
          plugin.run([])
        end
      end
    end

    # This section of specs heavily mocks the OpenSearch::Client, and ensures that the OpenSearch Input Plugin
    # behaves as expected when handling a series of sliced, scrolled requests/responses.
    context 'adapter/integration' do
      let(:response_template) do
        {
            "took" => 12,
            "timed_out" => false,
            "shards" => {
                "total" => 6,
                "successful" => 6,
                "failed" => 0
            }
        }
      end

      let(:hits_template) do
        {
            "total" => 4,
            "max_score" => 1.0,
            "hits" => []
        }
      end

      let(:hit_template) do
        {
            "_index" => "logstash-2018.08.23",
            "_type" => "logs",
            "_score" => 1.0,
            "_source" => { "message" => ["hello, world"] }
        }
      end

      # BEGIN SLICE 0: a sequence of THREE scrolled responses containing 2, 1, and 0 items
      # end-of-slice is reached when slice0_response2 is empty.
      begin
        let(:slice0_response0) do
          response_template.merge({
              "_scroll_id" => slice0_scroll1,
              "hits" => hits_template.merge("hits" => [
                  hit_template.merge('_id' => "slice0-response0-item0"),
                  hit_template.merge('_id' => "slice0-response0-item1")
                  ])
          })
        end
        let(:slice0_scroll1) { 'slice:0,scroll:1' }
        let(:slice0_response1) do
          response_template.merge({
              "_scroll_id" => slice0_scroll2,
              "hits" => hits_template.merge("hits" => [
                  hit_template.merge('_id' => "slice0-response1-item0")
              ])
          })
        end
        let(:slice0_scroll2) { 'slice:0,scroll:2' }
        let(:slice0_response2) do
          response_template.merge(
              "_scroll_id" => slice0_scroll3,
              "hits" => hits_template.merge({"hits" => []})
          )
        end
        let(:slice0_scroll3) { 'slice:0,scroll:3' }
      end
      # END SLICE 0

      # BEGIN SLICE 1: a sequence of TWO scrolled responses containing 2 and 2 items.
      # end-of-slice is reached when slice1_response1 does not contain a next scroll id
      begin
        let(:slice1_response0) do
          response_template.merge({
              "_scroll_id" => slice1_scroll1,
              "hits" => hits_template.merge("hits" => [
                  hit_template.merge('_id' => "slice1-response0-item0"),
                  hit_template.merge('_id' => "slice1-response0-item1")
              ])
          })
        end
        let(:slice1_scroll1) { 'slice:1,scroll:1' }
        let(:slice1_response1) do
          response_template.merge({
              "hits" => hits_template.merge("hits" => [
                  hit_template.merge('_id' => "slice1-response1-item0"),
                  hit_template.merge('_id' => "slice1-response1-item1")
              ])
          })
        end
      end
      # END SLICE 1

      let(:client) { OpenSearch::Client.new }

      # RSpec mocks validations are not threadsafe.
      # Allow caller to synchronize.
      def synchronize_method!(object, method_name)
        original_method = object.method(method_name)
        mutex = Mutex.new
        allow(object).to receive(method_name).with(any_args) do |*method_args, &method_block|
          mutex.synchronize do
            original_method.call(*method_args,&method_block)
          end
        end
      end

      before(:each) do
        expect(OpenSearch::Client).to receive(:new).with(any_args).and_return(client)
        plugin.register

        expect(client).to receive(:clear_scroll).and_return(nil)

        # SLICE0 is a three-page scroll in which the last page is empty
        slice0_query = LogStash::Json.dump(query.merge('slice' => { 'id' => 0, 'max' => 2}))
        expect(client).to receive(:search).with(hash_including(:body => slice0_query)).and_return(slice0_response0)
        expect(client).to receive(:scroll).with(hash_including(:body => { :scroll_id => slice0_scroll1 })).and_return(slice0_response1)
        expect(client).to receive(:scroll).with(hash_including(:body => { :scroll_id => slice0_scroll2 })).and_return(slice0_response2)
        allow(client).to receive(:ping)

        # SLICE1 is a two-page scroll in which the last page has no next scroll id
        slice1_query = LogStash::Json.dump(query.merge('slice' => { 'id' => 1, 'max' => 2}))
        expect(client).to receive(:search).with(hash_including(:body => slice1_query)).and_return(slice1_response0)
        expect(client).to receive(:scroll).with(hash_including(:body => { :scroll_id => slice1_scroll1 })).and_return(slice1_response1)

        synchronize_method!(plugin, :scroll_request)
        synchronize_method!(plugin, :search_request)
      end

      let(:emitted_events) do
        queue = Queue.new # since we are running slices in threads, we need a thread-safe queue.
        plugin.run(queue)
        events = []
        events << queue.pop until queue.empty?
        events
      end

      let(:emitted_event_ids) do
        emitted_events.map { |event| event.get('[@metadata][_id]') }
      end

      it 'emits the hits on the first page of the first slice' do
        expect(emitted_event_ids).to include('slice0-response0-item0')
        expect(emitted_event_ids).to include('slice0-response0-item1')
      end
      it 'emits the hits on the second page of the first slice' do
        expect(emitted_event_ids).to include('slice0-response1-item0')
      end

      it 'emits the hits on the first page of the second slice' do
        expect(emitted_event_ids).to include('slice1-response0-item0')
        expect(emitted_event_ids).to include('slice1-response0-item1')
      end

      it 'emits the hitson the second page of the second slice' do
        expect(emitted_event_ids).to include('slice1-response1-item0')
        expect(emitted_event_ids).to include('slice1-response1-item1')
      end

      it 'does not double-emit' do
        expect(emitted_event_ids.uniq).to eq(emitted_event_ids)
      end

      it 'emits events with appropriate fields' do
        emitted_events.each do |event|
          expect(event).to be_a(LogStash::Event)
          expect(event.get('message')).to eq(['hello, world'])
          expect(event.get('[@metadata][_id]')).to_not be_nil
          expect(event.get('[@metadata][_id]')).to_not be_empty
          expect(event.get('[@metadata][_index]')).to start_with('logstash-')
        end
      end
    end
  end

  context "with OpenSearch document information" do
    let!(:response) do
      {
        "_scroll_id" => "cXVlcnlUaGVuRmV0Y2g",
        "took" => 27,
        "timed_out" => false,
        "_shards" => {
          "total" => 169,
          "successful" => 169,
          "failed" => 0
        },
        "hits" => {
          "total" => 1,
          "max_score" => 1.0,
          "hits" => [ {
            "_index" => "logstash-2014.10.12",
            "_type" => "logs",
            "_id" => "C5b2xLQwTZa76jBmHIbwHQ",
            "_score" => 1.0,
            "_source" => {
              "message" => ["ohayo"],
              "metadata_with_hash" => { "awesome" => "logstash" },
              "metadata_with_string" => "a string"
            }
          } ]
        }
      }
    end

    let(:scroll_reponse) do
      {
        "_scroll_id" => "r453Wc1jh0caLJhSDg",
        "hits" => { "hits" => [] }
      }
    end

    let(:client) { OpenSearch::Client.new }

    before do
      expect(OpenSearch::Client).to receive(:new).with(any_args).and_return(client)
      expect(client).to receive(:search).with(any_args).and_return(response)
      allow(client).to receive(:scroll).with({ :body => {:scroll_id => "cXVlcnlUaGVuRmV0Y2g"}, :scroll => "1m" }).and_return(scroll_reponse)
      allow(client).to receive(:clear_scroll).and_return(nil)
      allow(client).to receive(:ping).and_return(nil)
    end

    ecs_compatibility_matrix(:disabled, :v1, :v8) do |ecs_select|

      before(:each) do
        allow_any_instance_of(described_class).to receive(:ecs_compatibility).and_return(ecs_compatibility)
      end

      context 'with docinfo enabled' do
        let(:config_metadata) do
          %q[
              input {
                opensearch {
                  hosts => ["localhost"]
                  query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
                  docinfo => true
                }
              }
          ]
        end

        it "provides document info under metadata" do
          event = input(config_metadata) do |pipeline, queue|
            queue.pop
          end

          if ecs_select.active_mode == :disabled
            expect(event.get("[@metadata][_index]")).to eq('logstash-2014.10.12')
            expect(event.get("[@metadata][_type]")).to eq('logs')
            expect(event.get("[@metadata][_id]")).to eq('C5b2xLQwTZa76jBmHIbwHQ')
          else
            expect(event.get("[@metadata][input][opensearch][_index]")).to eq('logstash-2014.10.12')
            expect(event.get("[@metadata][input][opensearch][_type]")).to eq('logs')
            expect(event.get("[@metadata][input][opensearch][_id]")).to eq('C5b2xLQwTZa76jBmHIbwHQ')
          end
        end

        it 'merges values if the `docinfo_target` already exist in the `_source` document' do
          config_metadata_with_hash = %Q[
              input {
                opensearch {
                  hosts => ["localhost"]
                  query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
                  docinfo => true
                  docinfo_target => 'metadata_with_hash'
                }
              }
          ]

          event = input(config_metadata_with_hash) do |pipeline, queue|
            queue.pop
          end

          expect(event.get("[metadata_with_hash][_index]")).to eq('logstash-2014.10.12')
          expect(event.get("[metadata_with_hash][_type]")).to eq('logs')
          expect(event.get("[metadata_with_hash][_id]")).to eq('C5b2xLQwTZa76jBmHIbwHQ')
          expect(event.get("[metadata_with_hash][awesome]")).to eq("logstash")
        end

        context 'if the `docinfo_target` exist but is not of type hash' do
          let (:config) { {
              "hosts" => ["localhost"],
              "query" => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }',
              "docinfo" => true,
              "docinfo_target" => 'metadata_with_string'
          } }
          it 'thows an exception if the `docinfo_target` exist but is not of type hash' do
            expect(client).not_to receive(:clear_scroll)
            plugin.register
            expect { plugin.run([]) }.to raise_error(Exception, /incompatible event/)
          end
        end

        it 'should move the document information to the specified field' do
          config = %q[
              input {
                opensearch {
                  hosts => ["localhost"]
                  query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
                  docinfo => true
                  docinfo_target => 'meta'
                }
              }
          ]
          event = input(config) do |pipeline, queue|
            queue.pop
          end

          expect(event.get("[meta][_index]")).to eq('logstash-2014.10.12')
          expect(event.get("[meta][_type]")).to eq('logs')
          expect(event.get("[meta][_id]")).to eq('C5b2xLQwTZa76jBmHIbwHQ')
        end

        it "allows to specify which fields from the document info to save to metadata" do
          fields = ["_index"]
          config = %Q[
              input {
                opensearch {
                  hosts => ["localhost"]
                  query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
                  docinfo => true
                  docinfo_fields => #{fields}
                }
              }]

          event = input(config) do |pipeline, queue|
            queue.pop
          end

          meta_base = event.get(ecs_select.active_mode == :disabled ? "@metadata" : "[@metadata][input][opensearch]")
          expect(meta_base.keys).to eq(fields)
        end

        it 'should be able to reference metadata fields in `add_field` decorations' do
          config = %q[
            input {
              opensearch {
                hosts => ["localhost"]
                query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
                docinfo => true
                add_field => {
                  'identifier' => "foo:%{[@metadata][_type]}:%{[@metadata][_id]}"
                }
              }
            }
          ]

          event = input(config) do |pipeline, queue|
            queue.pop
          end

          expect(event.get('identifier')).to eq('foo:logs:C5b2xLQwTZa76jBmHIbwHQ')
        end if ecs_select.active_mode == :disabled

      end

    end

    context "when not defining the docinfo" do
      it 'should keep the document information in the root of the event' do
        config = %q[
          input {
            opensearch {
              hosts => ["localhost"]
              query => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }'
            }
          }
        ]
        event = input(config) do |pipeline, queue|
          queue.pop
        end

        expect(event.get("[@metadata]")).to be_empty
      end
    end
  end

  describe "client" do
    let(:config) do
      {

      }
    end
    let(:plugin) { described_class.new(config) }
    let(:event)  { LogStash::Event.new({}) }

    describe "cloud.id" do
      let(:valid_cloud_id) do
        'sample:dXMtY2VudHJhbDEuZ2NwLmNsb3VkLmVzLmlvJGFjMzFlYmI5MDI0MTc3MzE1NzA0M2MzNGZkMjZmZDQ2OjkyNDMkYTRjMDYyMzBlNDhjOGZjZTdiZTg4YTA3NGEzYmIzZTA6OTI0NA=='
      end

      let(:config) { super().merge({ 'cloud_id' => valid_cloud_id }) }

      it "should set host(s)" do
        plugin.register
        client = plugin.send(:client)

        expect( client.transport.instance_variable_get(:@seeds) ).to eql [{
                                                                              :scheme => "https",
                                                                              :host => "ac31ebb90241773157043c34fd26fd46.us-central1.gcp.cloud.es.io",
                                                                              :port => 9243,
                                                                              :path => "",
                                                                              :protocol => "https"
                                                                          }]
      end

      context 'invalid' do
        let(:config) { super().merge({ 'cloud_id' => 'invalid:dXMtY2VudHJhbDEuZ2NwLmNsb3VkLmVzLmlv' }) }

        it "should fail" do
          expect { plugin.register }.to raise_error LogStash::ConfigurationError, /cloud_id.*? is invalid/
        end
      end

      context 'hosts also set' do
        let(:config) { super().merge({ 'cloud_id' => valid_cloud_id, 'hosts' => [ 'localhost:9200' ] }) }

        it "should fail" do
          expect { plugin.register }.to raise_error LogStash::ConfigurationError, /cloud_id and hosts/
        end
      end
    end if LOGSTASH_VERSION > '6.0'

    describe "cloud.auth" do
      let(:config) { super().merge({ 'cloud_auth' => LogStash::Util::Password.new('elastic:my-passwd-00') }) }

      it "should set authorization" do
        plugin.register
        client = plugin.send(:client)
        auth_header = extract_transport(client).options[:transport_options][:headers]['Authorization']

        expect( auth_header ).to eql "Basic #{Base64.encode64('elastic:my-passwd-00').rstrip}"
      end

      context 'invalid' do
        let(:config) { super().merge({ 'cloud_auth' => 'invalid-format' }) }

        it "should fail" do
          expect { plugin.register }.to raise_error LogStash::ConfigurationError, /cloud_auth.*? format/
        end
      end

      context 'user also set' do
        let(:config) { super().merge({ 'cloud_auth' => 'elastic:my-passwd-00', 'user' => 'another' }) }

        it "should fail" do
          expect { plugin.register }.to raise_error LogStash::ConfigurationError, /Multiple authentication options are specified/
        end
      end
    end if LOGSTASH_VERSION > '6.0'

    describe "api_key" do
      context "without ssl" do
        let(:config) { super().merge({ 'api_key' => LogStash::Util::Password.new('foo:bar') }) }

        it "should fail" do
          expect { plugin.register }.to raise_error LogStash::ConfigurationError, /api_key authentication requires SSL\/TLS/
        end
      end

      context "with ssl" do
        let(:config) { super().merge({ 'api_key' => LogStash::Util::Password.new('foo:bar'), "ssl" => true }) }

        it "should set authorization" do
          plugin.register
          client = plugin.send(:client)
          auth_header = extract_transport(client).options[:transport_options][:headers]['Authorization']

          expect( auth_header ).to eql "ApiKey #{Base64.strict_encode64('foo:bar')}"
        end

        context 'user also set' do
          let(:config) { super().merge({ 'api_key' => 'foo:bar', 'user' => 'another' }) }

          it "should fail" do
            expect { plugin.register }.to raise_error LogStash::ConfigurationError, /Multiple authentication options are specified/
          end
        end
      end
    end if LOGSTASH_VERSION > '6.0'

    describe "proxy" do
      let(:config) { super().merge({ 'proxy' => 'http://localhost:1234' }) }

      it "should set proxy" do
        plugin.register
        client = plugin.send(:client)
        proxy = extract_transport(client).options[:transport_options][:proxy]

        expect( proxy ).to eql "http://localhost:1234"
      end

      context 'invalid' do
        let(:config) { super().merge({ 'proxy' => '${A_MISSING_ENV_VAR:}' }) }

        it "should not set proxy" do
          plugin.register
          client = plugin.send(:client)

          expect( extract_transport(client).options[:transport_options] ).to_not include(:proxy)
        end
      end
    end

    class StoppableServer

      attr_reader :port

      def initialize()
        queue = Queue.new
        @first_req_waiter = java.util.concurrent.CountDownLatch.new(1)
        @first_request = nil

        @t = java.lang.Thread.new(
          proc do
            begin
              @server = WEBrick::HTTPServer.new :Port => 0, :DocumentRoot => ".",
                       :Logger => Cabin::Channel.get, # silence WEBrick logging
                       :StartCallback => Proc.new {
                             queue.push("started")
                           }
              @port = @server.config[:Port]
              @server.mount_proc '/' do |req, res|
                res.body = '''
                {
                    "name": "ce7ccfb438e8",
                    "cluster_name": "docker-cluster",
                    "cluster_uuid": "DyR1hN03QvuCWXRy3jtb0g",
                    "version": {
                        "number": "7.13.1",
                        "build_flavor": "default",
                        "build_type": "docker",
                        "build_hash": "9a7758028e4ea59bcab41c12004603c5a7dd84a9",
                        "build_date": "2021-05-28T17:40:59.346932922Z",
                        "build_snapshot": false,
                        "lucene_version": "8.8.2",
                        "minimum_wire_compatibility_version": "6.8.0",
                        "minimum_index_compatibility_version": "6.0.0-beta1"
                    },
                    "tagline": "You Know, for Search"
                }
                '''
                res.status = 200
                res['Content-Type'] = 'application/json'
                @first_request = req
                @first_req_waiter.countDown()
              end

              @server.mount_proc '/logstash_unit_test/_search' do |req, res|
                res.body = '''
                {
                  "took" : 1,
                  "timed_out" : false,
                  "_shards" : {
                    "total" : 1,
                    "successful" : 1,
                    "skipped" : 0,
                    "failed" : 0
                  },
                  "hits" : {
                    "total" : {
                      "value" : 10000,
                      "relation" : "gte"
                    },
                    "max_score" : 1.0,
                    "hits" : [
                      {
                        "_index" : "test_bulk_index_2",
                        "_type" : "_doc",
                        "_id" : "sHe6A3wBesqF7ydicQvG",
                        "_score" : 1.0,
                        "_source" : {
                          "@timestamp" : "2021-09-20T15:02:02.557Z",
                          "message" : "{\"name\": \"Andrea\"}",
                          "@version" : "1",
                          "host" : "kalispera",
                          "sequence" : 5
                        }
                      }
                    ]
                  }
                }
                '''
                res.status = 200
                res['Content-Type'] = 'application/json'
                @first_request = req
                @first_req_waiter.countDown()
              end



              @server.start
            rescue => e
              puts "Error in webserver thread #{e}"
              # ignore
            end
          end
        )
        @t.daemon = true
        @t.start
        queue.pop # blocks until the server is up
      end

      def stop
        @server.shutdown
      end

      def wait_receive_request
        @first_req_waiter.await(2, java.util.concurrent.TimeUnit::SECONDS)
        @first_request
      end
    end

    describe "'user-agent' header" do
      let!(:webserver) { StoppableServer.new } # webserver must be started before the call, so no lazy "let"

      after :each do
        webserver.stop
      end

      it "server should be started" do
        require 'net/http'
        response = nil
        Net::HTTP.start('localhost', webserver.port) {|http|
          response = http.request_get('/')
        }
        expect(response.code.to_i).to eq(200)
      end

      context "used by plugin" do
        let(:config) do
          {
            "hosts" => ["localhost:#{webserver.port}"],
            "query" => '{ "query": { "match": { "statuscode": 200 } }, "sort": [ "_doc" ] }',
            "index" => "logstash_unit_test"
          }
        end
        let(:plugin) { described_class.new(config) }
        let(:event)  { LogStash::Event.new({}) }

        it "client should sent the expect user-agent" do
          plugin.register

          queue = []
          plugin.run(queue)

          request = webserver.wait_receive_request

          expect(request.header['user-agent'].size).to eq(1)
          expect(request.header['user-agent'][0]).to match(/logstash\/\d*\.\d*\.\d* \(OS=.*; JVM=.*\) logstash-input-opensearch\/\d*\.\d*\.\d*/)
        end
      end
    end

    shared_examples 'configurable timeout' do |config_name, manticore_transport_option|
      let(:config_value) { fail NotImplementedError }
      let(:config) { super().merge(config_name => config_value) }
      {
          :string   => 'banana',
          :negative => -123,
          :zero     => 0,
      }.each do |value_desc, value|
        let(:config_value) { value }
        context "with an invalid #{value_desc} value" do
          it 'prevents instantiation with a helpful message' do
            expect(described_class.logger).to receive(:error).with(/Expected positive whole number/)
            expect { described_class.new(config) }.to raise_error(LogStash::ConfigurationError)
          end
        end
      end

      context 'with a valid value' do
        let(:config_value) { 17 }

        it "instantiates the opensearch client with the timeout value set via #{manticore_transport_option} in the transport options" do
          expect(OpenSearch::Client).to receive(:new) do |new_opensearch_client_params|
            # We rely on Manticore-specific transport options, fail early if we are using a different
            # transport or are allowing the client to determine its own transport class.
            expect(new_opensearch_client_params).to include(:transport_class)
            expect(new_opensearch_client_params[:transport_class].name).to match(/\bManticore\b/)

            expect(new_opensearch_client_params).to include(:transport_options)
            transport_options = new_opensearch_client_params[:transport_options]
            expect(transport_options).to include(manticore_transport_option)
            expect(transport_options[manticore_transport_option]).to eq(config_value.to_i)
            mock_client = double("fake_client")
            allow(mock_client).to receive(:ping)
            mock_client
          end

          plugin.register
        end
      end
    end

    context 'connect_timeout_seconds' do
      include_examples('configurable timeout', 'connect_timeout_seconds', :connect_timeout)
    end
    context 'request_timeout_seconds' do
      include_examples('configurable timeout', 'request_timeout_seconds', :request_timeout)
    end
    context 'socket_timeout_seconds' do
      include_examples('configurable timeout', 'socket_timeout_seconds', :socket_timeout)
    end
  end

  context "when scheduling" do
    let(:config) do
      {
        "hosts" => ["localhost"],
        "query" => '{ "query": { "match": { "city_name": "Okinawa" } }, "fields": ["message"] }',
        "schedule" => "* * * * * UTC"
      }
    end

    before do
      plugin.register
    end

    it "should properly schedule" do
      Timecop.travel(Time.new(2000))
      Timecop.scale(60)
      runner = Thread.new do
        expect(plugin).to receive(:do_run) {
          queue << LogStash::Event.new({})
        }.at_least(:twice)

        plugin.run(queue)
      end
      sleep 3
      plugin.stop
      runner.kill
      runner.join
      expect(queue.size).to eq(2)
      Timecop.return
    end

  end

  # @note can be removed once we depends on opensearch gem >= 6.x
  def extract_transport(client) # on 7.x client.transport is a OpenSearch::Transport::Client
    client.transport.respond_to?(:transport) ? client.transport.transport : client.transport
  end

end
