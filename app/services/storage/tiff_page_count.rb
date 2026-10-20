require "tempfile"

module Storage
  class TiffPageCount
    MAX_PAGES = 1_000_000

    def self.call(binary)
      new(binary).call
    end

    def self.each_page(binary, &block)
      new(binary).each_page(&block)
    end

    def initialize(binary)
      @binary = binary
    end

    def call
      directories&.length
    end

    def each_page
      pages = directories
      return unless pages

      offset_size = bigtiff ? 8 : 4
      first_pointer = bigtiff ? 8 : 4
      Tempfile.create("recify-tiff", anonymous: true, binmode: true) do |file|
        file.binmode
        file.write(binary)
        pages.each do |offset, next_pointer|
          begin
            write_pointer(file, first_pointer, [ offset ].pack(integer_format(offset_size)))
            write_pointer(file, next_pointer, "\0" * offset_size)
            file.flush
            file.rewind
            # Finish reading this private page before restoring its pointers.
            yield file
          ensure
            write_pointer(file, first_pointer, binary.byteslice(first_pointer, offset_size))
            write_pointer(file, next_pointer, binary.byteslice(next_pointer, offset_size))
            file.flush
          end
        end
      end
      pages.length
    end

    private

    attr_reader :binary, :little_endian, :bigtiff

    def write_pointer(file, offset, value)
      file.seek(offset)
      file.write(value)
    end

    def directories
      return unless binary.is_a?(String) && binary.bytesize >= 8
      return unless %w[II MM].include?(binary.byteslice(0, 2))

      @little_endian = binary.start_with?("II")
      version = read_integer(2, 2)
      return unless [ 42, 43 ].include?(version)

      @bigtiff = version == 43
      return if bigtiff && (read_integer(4, 2) != 8 || read_integer(6, 2) != 0)

      read_directories
    end

    def read_directories
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

        visited[offset] = next_pointer
        offset = next_offset
      end

      visited if visited.any?
    end

    def read_integer(offset, size)
      return if offset + size > binary.bytesize

      binary.unpack1(integer_format(size), offset:)
    end

    def integer_format(size)
      formats = little_endian ? { 2 => "v", 4 => "V", 8 => "Q<" } : { 2 => "n", 4 => "N", 8 => "Q>" }
      formats.fetch(size)
    end
  end
end
