require 'rails_helper'

RSpec.describe MobileChat::CardCopy do
  describe '.copy_for' do
    it 'returns the copy for an exact app locale' do
      expect(described_class.copy_for('zh_CN')['primary']).to eq('最佳匹配')
    end

    it 'returns the traditional copy for zh_Hant, not the simplified one' do
      expect(described_class.copy_for('zh_Hant')['primary']).to eq('最佳配對')
    end

    it 'returns the norwegian copy for no, which yaml would otherwise read as false' do
      expect(described_class.copy_for('no')['primary']).to eq('Beste treff')
    end

    it 'falls back to the language prefix for a regional variant' do
      expect(described_class.copy_for('en_GB')['validity']).to eq('Validity')
    end

    # The website ships a bare `pt` (esimgo-web locales.ts), so without canonicalization the
    # lookup misses every Portuguese entry and the card renders in English. Its copy and pt_PT's
    # are identical strings today, so this pins the entry rather than the wording.
    it 'canonicalizes a bare pt to the brazilian copy' do
      expect(described_class.copy_for('pt')).to be(described_class.dictionaries['pt_BR'])
    end

    it 'keeps an explicit pt_PT on the european copy' do
      expect(described_class.copy_for('pt_PT')).to be(described_class.dictionaries['pt_PT'])
    end

    it 'treats a traditional chinese qualifier as zh_Hant' do
      expect(described_class.copy_for('zh-TW')['primary']).to eq('最佳配對')
    end

    it 'treats a bare zh as simplified chinese' do
      expect(described_class.copy_for('zh')['primary']).to eq('最佳匹配')
    end

    it 'maps the legacy filipino code to the tagalog copy' do
      expect(described_class.copy_for('fil')['primary']).to eq('Pinakamahusay')
    end

    it 'picks the mexican copy for es-MX' do
      expect(described_class.copy_for('es-MX')['validity']).to eq('Vigencia')
    end

    it 'falls back to the bare language for a region the dictionary does not carry' do
      expect(described_class.copy_for('de_DE')['primary']).to eq('Beste Wahl')
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

    it 'falls back when the text carries a table' do
      expect(described_class.sanitize_description("| Plan | Data |\n| 7 days | 10 GB |", fallback)).to eq(fallback)
    end

    it 'keeps a single pipe, which is ordinary punctuation' do
      expect(described_class.sanitize_description('7 days | 10 GB', fallback)).to eq('7 days | 10 GB')
    end

    it 'keeps prose that only has a colon and a space' do
      expect(described_class.sanitize_description('Data: 10 GB, Validity: 7 days', fallback)).to eq('Data: 10 GB, Validity: 7 days')
    end

    it 'falls back when a scheme carries a payload' do
      expect(described_class.sanitize_description('data:text/html;base64,AAAA', fallback)).to eq(fallback)
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

  describe '.web_locale_prefix' do
    # The store's paths use hyphens where the app writes an underscore.
    it 'spells the language the way the store does' do
      expect(described_class.web_locale_prefix('zh_CN')).to eq('/zh-CN')
    end

    it 'canonicalizes first, so a regional variant still reaches the store path' do
      expect(described_class.web_locale_prefix('zh-Hant')).to eq('/zh-Hant')
      expect(described_class.web_locale_prefix('pt')).to eq('/pt-BR')
    end

    it 'leaves the prefix off english, which is the store root' do
      expect(described_class.web_locale_prefix('en')).to eq('')
      expect(described_class.web_locale_prefix('en_GB')).to eq('')
    end

    # Anything the copy dictionary does not carry canonicalizes to english, so it lands on the root
    # rather than on a path the store does not serve.
    it 'leaves the prefix off a language the store does not serve' do
      expect(described_class.web_locale_prefix('xx_YY')).to eq('')
    end
  end
end
