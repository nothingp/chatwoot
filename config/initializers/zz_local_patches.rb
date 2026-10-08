# Local-only patch for the upstream-comparison instance. Does not exist upstream.
#
# It is baked into the image built from this repository by
# .github/workflows/publish_fork_image.yml, and deployed with
# deploy/upstream-comparison/deploy.sh. The `zz_` prefix makes it load last.
#
# Raises Concerns::CaptainMarkdownDocumentable::MARKDOWN_MAX_LENGTH from 10_000
# so a full support manual imports as one document. Document#content has its own
# 200_000 validation, so 10_000 is a product choice, not a hard ceiling.
Rails.application.config.after_initialize do
  begin
    markdown_concern = Concerns::CaptainMarkdownDocumentable
    if markdown_concern.const_defined?(:MARKDOWN_MAX_LENGTH, false)
      markdown_concern.send(:remove_const, :MARKDOWN_MAX_LENGTH)
    end
    markdown_concern.const_set(:MARKDOWN_MAX_LENGTH, 50_000)
    Rails.logger.info "[local] MARKDOWN_MAX_LENGTH=#{markdown_concern::MARKDOWN_MAX_LENGTH}"
  rescue StandardError => e
    Rails.logger.error "[local] failed to raise MARKDOWN_MAX_LENGTH: #{e.class}: #{e.message}"
  end
end
