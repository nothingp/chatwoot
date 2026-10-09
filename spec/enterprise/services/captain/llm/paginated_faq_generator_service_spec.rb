require 'rails_helper'

RSpec.describe Captain::Llm::PaginatedFaqGeneratorService do
  let(:document) { create(:captain_document) }
  let(:service) { described_class.new(document, pages_per_chunk: 5) }
  let(:openai_client) { instance_double(OpenAI::Client) }

  before do
    # Mock OpenAI configuration
    installation_config = instance_double(InstallationConfig, value: 'test-api-key')
    allow(InstallationConfig).to receive(:find_by!)
      .with(name: 'CAPTAIN_OPEN_AI_API_KEY')
      .and_return(installation_config)

    allow(OpenAI::Client).to receive(:new).and_return(openai_client)
  end

  describe '#generate' do
    it 'uses the model the router resolves, ignoring an override the feature no longer offers' do
      # pdf_faq_generation only offers qwen-long, so a stale override of a model that cannot read
      # fileid:// is dropped by the router instead of reaching the guard in the constructor.
      document.account.update!(captain_models: { 'pdf_faq_generation' => 'gpt-5.2' })

      expect(service.model).to eq('qwen-long')
    end

    context 'when document lacks OpenAI file ID' do
      before do
        allow(document).to receive(:openai_file_id).and_return(nil)
      end

      it 'raises an error' do
        expect { service.generate }.to raise_error(CustomExceptions::Pdf::FaqGenerationError)
      end
    end

    context 'when generating FAQs from PDF pages' do
      let(:faq_response) do
        {
          'choices' => [{
            'message' => {
              'content' => JSON.generate({
                                           'faqs' => [
                                             { 'question' => 'What is this document about?', 'answer' => 'It explains key concepts.' }
                                           ],
                                           'has_content' => true
                                         })
            }
          }]
        }
      end

      let(:empty_response) do
        {
          'choices' => [{
            'message' => {
              'content' => JSON.generate({
                                           'faqs' => [],
                                           'has_content' => false
                                         })
            }
          }]
        }
      end

      before do
        allow(document).to receive(:openai_file_id).and_return('file-123')
      end

      it 'generates FAQs from paginated content' do
        allow(openai_client).to receive(:chat).and_return(faq_response, empty_response)

        faqs = service.generate

        expect(faqs).to have_attributes(size: 1)
        expect(faqs.first['question']).to eq('What is this document about?')
      end

      it 'stops when no more content' do
        allow(openai_client).to receive(:chat).and_return(empty_response)

        faqs = service.generate

        expect(faqs).to be_empty
      end

      it 'respects max iterations limit' do
        allow(openai_client).to receive(:chat).and_return(faq_response)

        # Force max iterations
        service.instance_variable_set(:@iterations_completed, 19)

        service.generate
        expect(service.iterations_completed).to eq(20)
      end
    end
  end

  describe 'model guard' do
    it 'raises when the resolved model cannot read fileid:// references' do
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen3.8-flash')

      expect { described_class.new(document) }
        .to raise_error(CustomExceptions::Pdf::FaqGenerationError, %r{fileid://.*qwen3\.8-flash})
    end

    it 'accepts qwen-long' do
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen-long')

      expect { described_class.new(document) }.not_to raise_error
    end
  end

  describe '#build_chunk_parameters' do
    before do
      allow(document).to receive(:openai_file_id).and_return('file-123')
      allow(Llm::FeatureRouter).to receive(:resolve).and_return(model: 'qwen-long')
    end

    it 'references the uploaded file through a fileid system message' do
      service = described_class.new(document)

      params = service.send(:build_chunk_parameters, 1, 10)

      expect(params[:messages].first).to eq(role: 'system', content: "fileid://#{document.openai_file_id}")
    end

    it 'keeps the chunk instructions in the user message' do
      service = described_class.new(document, pages_per_chunk: 5)

      params = service.send(:build_chunk_parameters, 1, 10)

      expect(params[:messages].map { |message| message[:role] }).to eq(%w[system user])
      expect(params[:messages].last[:content]).to include('page 1')
    end
  end

  describe '#should_continue_processing?' do
    it 'stops at max iterations' do
      service.instance_variable_set(:@iterations_completed, 20)
      expect(service.should_continue_processing?(faqs: ['faq'], has_content: true)).to be false
    end

    it 'stops when no FAQs returned' do
      expect(service.should_continue_processing?(faqs: [], has_content: true)).to be false
    end

    it 'continues when FAQs exist and under limits' do
      expect(service.should_continue_processing?(faqs: ['faq'], has_content: true)).to be true
    end
  end
end
