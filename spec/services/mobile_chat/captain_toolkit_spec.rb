require 'rails_helper'

RSpec.describe MobileChat::CaptainToolkit do
  let(:account) { create(:account) }
  let(:orders_url) { 'https://api.example.com/api/v2/esim/user/orders' }
  let(:recommendations_url) { 'https://api.example.com/api/v2/esim/product/recommendations' }
  let(:search_url) { 'https://api.example.com/api/v2/esim/product/search' }
  let(:contact) do
    create(:contact, account: account, identifier: 'member_12345',
                     custom_attributes: { 'app_token' => 'member-token' })
  end
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:toolkit) { described_class.new(conversation) }

  before do
    create(:installation_config, name: 'NOVYRO_API_BASE_URL', value: 'https://api.example.com/api')
    create(:installation_config, name: 'NOVYRO_USER_ORDERS_PATH', value: '/v2/esim/user/orders')
    create(:installation_config, name: 'NOVYRO_API_KEY', value: 'service-key')
    create(:installation_config, name: 'NOVYRO_SITE_ID', value: '10000')

    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
  end

  describe '#list_orders' do
    it 'shapes an order and drops fields outside the whitelist' do
      stub_request(:get, orders_url).to_return(
        status: 200,
        body: {
          code: 1,
          data: {
            orders: [
              {
                order_no: 'A1001',
                order_status: 'completed',
                qr_code: 'SECRET-QR',
                order_goods: [
                  { product_name: 'Japan 5GB', data_size_gb: '5', billing_period_days: 7, iccid: 'SECRET-ICCID' }
                ]
              }
            ]
          }
        }.to_json
      )

      result = toolkit.list_orders

      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(1)
      order = result[:orders].first
      expect(order[:order_id]).to eq('A1001')
      expect(order[:status]).to eq('COMPLETED')
      # The SKU lives in a single-element order_goods array, not in `sku`.
      expect(order[:product_name]).to eq('Japan 5GB')
      expect(order[:data_size_value]).to eq('5')
      expect(order[:data_size_unit]).to eq('GB')
      expect(order[:billing_period_days]).to eq(7)
      expect(order.keys).to match_array(
        %i[order_id status product_name data_size_value data_size_unit billing_period_days]
      )
    end

    it 'sends the member token and the service credentials' do
      request = stub_request(:get, orders_url)
                .with(headers: { 'token' => 'member-token', 'x-api-key' => 'service-key', 'site-id' => '10000' })
                .to_return(status: 200, body: { code: 1, data: { orders: [] } }.to_json)

      expect(toolkit.list_orders[:ok]).to be(true)
      expect(request).to have_been_requested
    end

    it 'asks the customer to sign in without calling Novyro when there is no app token' do
      guest_contact = create(:contact, account: account, identifier: 'guest_a_b')
      guest_conversation = create(:conversation, account: account, contact: guest_contact)

      result = described_class.new(guest_conversation).list_orders

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq(MobileChat::CaptainToolkit::SIGN_IN_REQUIRED)
      expect(a_request(:get, orders_url)).not_to have_been_made
    end

    it 'asks the customer to sign in when Novyro rejects the token' do
      stub_request(:get, orders_url).to_return(status: 200, body: { code: 401, data: nil }.to_json)

      expect(toolkit.list_orders[:error]).to eq(MobileChat::CaptainToolkit::SIGN_IN_REQUIRED)
    end

    it 'treats the documented zero code as unavailable on the production host' do
      stub_request(:get, orders_url).to_return(status: 200, body: { code: 0, data: { orders: [] } }.to_json)

      expect(toolkit.list_orders[:error]).to eq(MobileChat::CaptainToolkit::UPSTREAM_UNAVAILABLE)
    end

    it 'reports upstream failures instead of raising' do
      stub_request(:get, orders_url).to_return(status: 500, body: 'boom')

      expect(toolkit.list_orders[:error]).to eq(MobileChat::CaptainToolkit::UPSTREAM_UNAVAILABLE)
    end

    it 'reports a timeout instead of raising' do
      stub_request(:get, orders_url).to_timeout

      expect(toolkit.list_orders[:error]).to eq(MobileChat::CaptainToolkit::UPSTREAM_UNAVAILABLE)
    end
  end

  describe '#get_order_details' do
    before do
      stub_request(:get, orders_url).to_return(
        status: 200,
        body: { code: 1, data: { orders: [{ order_no: 'A1001' }, { order_no: 'A1002' }] } }.to_json
      )
    end

    it 'finds the order by number' do
      result = toolkit.get_order_details({ order_no: 'A1002' })

      expect(result[:ok]).to be(true)
      expect(result[:order][:order_id]).to eq('A1002')
    end

    it 'rejects a call without an identifier without calling Novyro' do
      result = toolkit.get_order_details({})

      expect(result[:ok]).to be(false)
      expect(a_request(:get, orders_url)).not_to have_been_made
    end

    it 'reports an order that does not belong to the customer' do
      result = toolkit.get_order_details({ order_no: 'NOPE' })

      expect(result[:ok]).to be(false)
      expect(result[:error]).to include('No order')
    end
  end

  describe '#recommend_plans' do
    it 'rejects a call without both required parameters, without calling Novyro' do
      result = toolkit.recommend_plans({ country_code: 'JP' })

      expect(result[:ok]).to be(false)
      expect(a_request(:get, recommendations_url)).not_to have_been_made
    end

    it 'shapes the recommendations and their skus' do
      stub_request(:get, recommendations_url)
        .with(query: { country_code: 'JP', billing_period: '7' })
        .to_return(
          status: 200,
          body: {
            code: 1,
            data: {
              recommendations: [
                {
                  product_id: 13,
                  product_name: 'Japan',
                  country_code: 'JP',
                  country_image: 'https://cdn/JP.svg',
                  skus: [{ id: 13055, data_size_gb: '5', billing_period_days: 7, price: { 'USD' => '9.90' } }]
                }
              ]
            }
          }.to_json
        )

      result = toolkit.recommend_plans({ country_code: 'jp', billing_period: '7' })

      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(1)
      plan = result[:plans].first
      expect(plan[:product_id]).to eq(13)
      expect(plan[:name]).to eq('Japan')
      expect(plan[:skus].first[:sku_id]).to eq(13055)
      expect(plan[:skus].first[:data_size_value]).to eq('5')
    end
  end

  describe '#search_products' do
    it 'turns the all_products map into a list and keeps the id buckets' do
      stub_request(:get, search_url).with(query: { keyword: 'Japan' }).to_return(
        status: 200,
        body: {
          code: 1,
          data: {
            all_products: { '13' => { name: 'Japan', country_code: 'JP', min_sku_price: { 'USD' => '9.90' } } },
            country_products: ['13'],
            regional_products: ['27']
          }
        }.to_json
      )

      result = toolkit.search_products({ keyword: 'Japan' })

      expect(result[:ok]).to be(true)
      expect(result[:products].first[:product_id]).to eq('13')
      expect(result[:products].first[:name]).to eq('Japan')
      expect(result[:country_product_ids]).to eq(['13'])
      expect(result[:regional_product_ids]).to eq(['27'])
    end
  end

end
