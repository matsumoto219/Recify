module Storage
  class TiffPageCount
    MAX_PAGES = 1_000_000

    def self.call(binary)
      new(binary).call
    end

    def initialize(binary)
      @binary = binary
    end

    def call
      return unless binary.is_a?(String) && binary.bytesize >= 8
      return unless %w[II MM].include?(binary.byteslice(0, 2))

      @little_endian = binary.start_with?("II")
      version = read_integer(2, 2)
      return unless [ 42, 43 ].include?(version)

      @bigtiff = version == 43
      return if bigtiff && (read_integer(4, 2) != 8 || read_integer(6, 2) != 0)

      count_directories
    end

    private

    attr_reader :binary, :little_endian, :bigtiff

    def count_directories
      header_size, count_size, entry_size, offset_size = bigtiff ? [ 16, 8, 20, 8 ] : [ 8, 2, 12, 4 ]
      offset = read_integer(bigtiff ? 8 : 4, offset_size)
      page_limit = [ MAX_PAGES, binary.bytesize / (count_size + entry_size + offset_size) ].min
      visited = {}

      until offset == 0
        return unless offset && offset >= header_size
        return if visited.key?(offset) || visited.length >= page_limit

        count = read_integer(offset, count_size)
        return unless count&.positive?

        next_pointer = offset + count_size + count * entry_size
        next_offset = read_integer(next_pointer, offset_size)
        return unless next_offset

        visited[offset] = true
        offset = next_offset
      end

      visited.length if visited.any?
    end

    def read_integer(offset, size)
      return if offset + size > binary.bytesize

      formats = little_endian ? { 2 => "v", 4 => "V", 8 => "Q<" } : { 2 => "n", 4 => "N", 8 => "Q>" }
      binary.unpack1(formats.fetch(size), offset:)
    end
  end
end
