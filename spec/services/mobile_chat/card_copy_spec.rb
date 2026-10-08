require 'rails_helper'

RSpec.describe MobileChat::CardCopy do
  describe '.copy_for' do
    it 'returns the copy for an exact app locale' do
      expect(described_class.copy_for('zh_CN')['primary']).to eq('最佳匹配')
    end

    it 'returns the traditional copy for zh_Hant, not the simplified one' do
      expect(described_class.copy_for('zh_Hant')['primary']).to eq('最佳配對')
    end

    it 'falls back to the language prefix for a regional variant' do
      expect(described_class.copy_for('en_GB')['validity']).to eq('Validity')
    end

    it 'falls back to english for an unknown locale' do
      expect(described_class.copy_for('xx')).to eq(described_class.copy_for('en'))
    end

    it 'falls back to english when the locale is blank' do
      expect(described_class.copy_for(nil)).to eq(described_class.copy_for('en'))
    end

    it 'raises when the english dictionary is missing' do
      allow(described_class).to receive(:dictionaries).and_return({ 'zh_CN' => { 'primary' => '最佳匹配' } })

      expect { described_class.copy_for('fr') }.to raise_error(CustomExceptions::MobileChat::NotConfigured)
    end
  end

  describe '.sanitize_description' do
    let(:fallback) { described_class.copy_for('en')['description'] }

    it 'keeps plain text' do
      expect(described_class.sanitize_description('7 days in Japan, 10 GB.', fallback)).to eq('7 days in Japan, 10 GB.')
    end

    it 'collapses whitespace and drops control characters' do
      expect(described_class.sanitize_description("7 days\n\tin Japan", fallback)).to eq('7 days in Japan')
    end

    it 'falls back when the text carries a link' do
      expect(described_class.sanitize_description('See https://novyro.com/plan', fallback)).to eq(fallback)
    end

    it 'falls back when the text carries a bare domain' do
      expect(described_class.sanitize_description('Buy at novyro.com', fallback)).to eq(fallback)
    end

    it 'falls back when the text carries markdown' do
      expect(described_class.sanitize_description('- 7 days in Japan', fallback)).to eq(fallback)
      expect(described_class.sanitize_description('[plan](x)', fallback)).to eq(fallback)
    end

    it 'falls back when the text is longer than the limit' do
      expect(described_class.sanitize_description('a' * 501, fallback)).to eq(fallback)
    end

    it 'falls back when the text has more than one emoji' do
      expect(described_class.sanitize_description('🎌🇯🇵 plan', fallback)).to eq(fallback)
    end

    it 'falls back when the text is blank' do
      expect(described_class.sanitize_description('  ', fallback)).to eq(fallback)
      expect(described_class.sanitize_description(nil, fallback)).to eq(fallback)
    end
  end

  describe '.sanitize_action_text' do
    let(:fallback) { described_class.copy_for('en')['cta'] }

    it 'keeps a short label' do
      expect(described_class.sanitize_action_text('View plan', fallback)).to eq('View plan')
    end

    it 'falls back when the label is longer than the action text limit' do
      expect(described_class.sanitize_action_text('a' * 121, fallback)).to eq(fallback)
    end
  end
end
