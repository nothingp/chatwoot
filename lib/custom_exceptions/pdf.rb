module CustomExceptions::Pdf
  class UploadError < CustomExceptions::Base
    def initialize(message = 'PDF upload failed')
      super(message)
    end
  end

  class ValidationError < CustomExceptions::Base
    def initialize(message = 'PDF validation failed')
      super(message)
    end
  end

  class FaqGenerationError < CustomExceptions::Base
    def initialize(message = 'PDF FAQ generation failed')
      super(message)
    end

    # Base#initialize sets @data but calls super() with no arguments, so the message passed to the
    # raise is otherwise lost and callers only see the class name. Same pattern as CustomExceptions::Account.
    def message
      @data
    end
  end
end
