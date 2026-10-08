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
    create(:installation_config, name: 'NOVYRO_CATALOG_ENVIRONMENT', value: 'test')

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
    it 'sends the customer language and currency upstream' do
      contact.update!(custom_attributes: contact.custom_attributes.merge('locale' => 'zh_CN', 'currency' => 'CNY'))
      stub_request(:get, recommendations_url)
        .with(query: { country_code: 'JP', billing_period: '7' },
              headers: { 'lang' => 'zh_CN', 'currency' => 'CNY' })
        .to_return(status: 200, body: { code: 1, data: { recommendations: [] } }.to_json)

      expect(described_class.new(conversation).recommend_plans({ country_code: 'JP', billing_period: 7 })[:ok]).to be(true)
    end

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
                  skus: [
                    { id: 13055, data_size_gb: '5', billing_period_days: 7, price: { 'USD' => '9.90' } },
                    { id: 13056, data_size_gb: '0', data_size_is_unlimited: true, price: { 'USD' => '35.99' } }
                  ]
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
      # Unlimited SKUs report their size as 0 upstream, which must not read as "0 GB".
      unlimited = plan[:skus].last
      expect(unlimited[:sku_id]).to eq(13056)
      expect(unlimited[:data_unlimited]).to be(true)
      expect(unlimited).not_to have_key(:data_size_value)
      expect(unlimited).not_to have_key(:data_size_unit)
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

  describe '#purchase_actions' do
    let(:product_details_url) { 'https://api.example.com/api/v2/esim/product/details' }
    let(:contact) do
      create(:contact, account: account, identifier: 'member_12345',
                       custom_attributes: { 'app_token' => 'member-token', 'locale' => 'zh_CN',
                                            'currency' => 'USD', 'catalog_environment' => 'prod' })
    end
    let(:params) { { 'product_id' => '13', 'sku_ids' => %w[13055 13056], 'reason' => '7天日本专属行程，10GB总量。', 'label' => '日本 7日 10GB 总量套餐' } }

    # The test env has no FRONTEND_URL, and the checkout uri is built from it; the repo helper is
    # the sanctioned way to set env in specs.
    around do |example|
      with_modified_env(FRONTEND_URL: 'https://app.example.com') { example.run }
    end

    before do
      stub_request(:get, product_details_url)
        .with(query: { product_id: '13' }, headers: { 'lang' => 'zh_CN', 'currency' => 'USD' })
        .to_return(
          status: 200,
          body: {
            code: 1,
            data: {
              product_id: 13,
              name: '日本',
              country_code: 'JP',
              country_image: 'https://cdn/JP.svg',
              skus: [
                { id: 13_055, data_size_gb: '10', billing_period_days: 7, price: { 'USD' => '16.99' } },
                { id: 13_056, data_size_gb: '0', data_size_is_unlimited: true, billing_period_days: 7, price: { 'USD' => '35.99' } },
                { id: 13_057, data_size_gb: '3', billing_period_days: 7, price: { 'USD' => '5.99' } },
                { id: 13_058, data_size_gb: '3', billing_period_days: 7, price: { 'USD' => '5.99' } },
                { id: 13_059, data_size_gb: '3', billing_period_days: 7, price: { 'USD' => '5.99' } },
                { id: 13_060, data_size_gb: '3', billing_period_days: 7, price: { 'USD' => '5.99' } }
              ]
            }
          }.to_json
        )
    end

    it 'builds one card per sku, primary first, with the copy for the customer locale' do
      result = toolkit.purchase_actions(params)

      expect(result[:ok]).to be(true)
      primary, alternative = result[:cards]
      expect(primary[:title]).to eq('日本')
      expect(primary[:badge]).to eq('最佳匹配')
      expect(primary[:description]).to eq('7天日本专属行程，10GB总量。')
      expect(primary[:media_url]).to eq('')
      expect(alternative[:badge]).to eq('备选方案')
      expect(alternative[:description]).to eq('已核实套餐方案。')
    end

    it 'takes facts from the upstream sku' do
      facts = toolkit.purchase_actions(params)[:cards].first[:facts]

      expect(facts).to eq(
        [
          { icon: 'wifi', label: '流量', value: '10 GB' },
          { icon: 'calendar', label: '有效期', value: '7天' },
          { icon: 'wallet', label: '价格', value: 'USD 16.99' }
        ]
      )
    end

    it 'labels an unlimited sku with the copied wording' do
      facts = toolkit.purchase_actions(params)[:cards].last[:facts]

      expect(facts.first).to eq(icon: 'wifi', label: '流量', value: '无限流量')
    end

    it 'builds the checkout uri from the frontend url and the recorded catalog environment' do
      action = toolkit.purchase_actions(params)[:cards].first[:actions].first

      expect(action[:type]).to eq('link')
      expect(action[:text]).to eq('日本 7日 10GB 总量套餐')
      expect(action[:uri]).to eq('https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=prod')
    end

    it 'falls back to the shipped copy when the model text carries a link' do
      result = toolkit.purchase_actions(params.merge('reason' => 'see https://novyro.com'))

      expect(result[:cards].first[:description]).to eq('已核实套餐方案。')
    end

    it 'refuses a sku that is not in the product' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => %w[13055 99999]))

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'refuses ids that are not numeric' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => ['../etc']))

      expect(result[:ok]).to be(false)
    end

    it 'takes at most five skus' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => %w[13055 13056 13057 13058 13059 13060]))

      expect(result[:cards].size).to eq(5)
    end

    it 'refuses an empty sku list' do
      expect(toolkit.purchase_actions(params.merge('sku_ids' => []))[:ok]).to be(false)
    end

    it 'collapses a repeated sku id into one card' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => %w[13055 13055]))

      expect(result[:cards].size).to eq(1)
    end

    # The three shapes below used to reach messages.create! and raise, which the caller turns into
    # a forced human handoff; they have to come back as an error the model can read instead.
    it 'refuses an id beyond the safe integer range before calling upstream' do
      result = toolkit.purchase_actions(params.merge('sku_ids' => ['9007199254740992']))

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
      expect(a_request(:get, product_details_url)).not_to have_been_made
    end

    it 'refuses a sku that fills no fact at all' do
      stub_request(:get, product_details_url)
        .with(query: { product_id: '13' })
        .to_return(status: 200, body: { code: 1, data: { product_id: 13, name: '日本', skus: [{ id: 13_055 }] } }.to_json)

      result = toolkit.purchase_actions(params.merge('sku_ids' => ['13055']))

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'refuses a product with no name to put on the card' do
      stub_request(:get, product_details_url)
        .with(query: { product_id: '13' })
        .to_return(
          status: 200,
          body: {
            code: 1,
            data: {
              product_id: 13, name: '',
              skus: [{ id: 13_055, data_size_gb: '10', billing_period_days: 7, price: { 'USD' => '16.99' } }]
            }
          }.to_json
        )

      result = toolkit.purchase_actions(params.merge('sku_ids' => ['13055']))

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it 'falls back to the configured catalog environment when the session did not record one' do
      without_environment = create(:contact, account: account, identifier: 'member_67890',
                                             custom_attributes: { 'app_token' => 'member-token', 'locale' => 'zh_CN',
                                                                  'currency' => 'USD' })

      action = described_class.new(create(:conversation, account: account, contact: without_environment))
                              .purchase_actions(params)[:cards].first[:actions].first

      expect(action[:uri]).to eq('https://app.example.com/app-actions/checkout?goods_id=13&sku_id=13055&catalog_env=test')
    end
  end

  describe 'without a conversation' do
    # The Playground passes no conversation in the tool context. The product tools need no
    # identity, so they must still work there.
    let(:toolkit) { described_class.new(nil) }

    it 'still answers public catalogue queries' do
      stub_request(:get, recommendations_url)
        .with(query: { country_code: 'JP', billing_period: '7' })
        .to_return(status: 200, body: { code: 1, data: { recommendations: [] } }.to_json)

      expect(toolkit.recommend_plans({ country_code: 'JP', billing_period: 7 })[:ok]).to be(true)
    end

    it 'reports orders as unavailable instead of raising' do
      result = toolkit.list_orders

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq(MobileChat::CaptainToolkit::SIGN_IN_REQUIRED)
      expect(a_request(:get, orders_url)).not_to have_been_made
    end
  end
end
