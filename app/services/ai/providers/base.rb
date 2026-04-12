module Ai
  module Providers
    class Base
      def call(_input)
        raise NotImplementedError, "provider client must implement #call"
      end
    end
  end
end
