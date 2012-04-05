module Symmetric
  class EncryptionReader
    # Read from encrypted files and other IO streams
    #
    # Features:
    # * Decryption on the fly whilst reading files
    # * Large file support by only buffering small amounts of data in memory
    #
    # # Example: Read and decrypt a line at a time from a file
    # Symmetric::EncryptionReader.open('test_file') do |file|
    #   file.each_line {|line| p line }
    # end
    #
    # # Example: Read and decrypt entire file in memory
    # # Not recommended for large files
    # Symmetric::EncryptionReader.open('test_file') {|f| f.read }
    #
    # # Example: Reading a limited number of bytes at a time from the file
    # Symmetric::EncryptionReader.open('test_file') do |file|
    #   file.read(1)
    #   file.read(5)
    #   file.read
    # end
    #
    # # Example: Read and decrypt 5 bytes at a time until the end of file is reached
    # Symmetric::EncryptionReader.open('test_file') do |file|
    #   while !file.eof? do
    #     file.read(5)
    #   end
    # end
    #
    # # Example: Read, Unencrypt and decompress data in a file
    # Symmetric::EncryptionReader.open('encrypted_compressed.zip', :compress => true) do |file|
    #   file.each_line {|line| p line }
    # end


    # Open a file for reading, or use the supplied IO Stream
    #
    # Parameters:
    #   filename_or_stream:
    #     The filename to open if a string, otherwise the stream to use
    #     The file or stream will be closed on completion, use .initialize to
    #     avoid having the stream closed automatically
    #
    #   options:
    #     :compress [true|false]
    #          Uses Zlib to decompress the data after it is decrypted
    #          # In the future, compression will be autodetected if a header is
    #          # present on the file/stream
    #          Default: false
    #
    #     :version
    #          Version of the encryption key to use when decrypting and the
    #          file/stream does not include a header at the beginning
    #          Default: Current primary key
    #
    #     :mode
    #          See File.open for open modes
    #          Default: 'r'
    #
    #     :buffer_size
    #          Amount of data to read at a time
    #          Default: 4096
    #
    # Note: Decryption occurs before decompression
    #
    def self.open(filename_or_stream, options={}, &block)
      raise "options must be a hash" unless options.respond_to?(:each_pair)
      mode = options.fetch(:mode, 'r')
      compress = options.fetch(:compress, false)
      ios = filename_or_stream.is_a?(String) ? ::File.open(filename_or_stream, mode) : filename_or_stream

      begin
        file = self.new(ios, options)
        file = Zlib::GzipReader.new(file) if compress
        block.call(file)
      ensure
        file.close if file
      end
    end

    # Decrypt data before reading from the supplied stream
    def initialize(ios,options={})
      @ios         = ios
      @buffer_size = options.fetch(:buffer_size, 4096).to_i
      @compressed  = nil
      @read_buffer = ''

      # Read first block and check for the header
      buf = @ios.read(@buffer_size)
      if buf.start_with?(Symmetric::Encryption::MAGIC_HEADER)
        # Header includes magic header and version byte
        # Remove header and extract flags
        header, flags = buf.slice!(0..MAGIC_HEADER_SIZE).unpack(MAGIC_HEADER_UNPACK)
        @compressed = flags & 0b1000_0000_0000_0000
        @version = @compressed ? flags - 0b1000_0000_0000_0000 : flags
      else
        @version = options[:version]
      end

      # Use primary cipher by default, but allow a secondary cipher to be selected for encryption
      @cipher = Encryption.cipher(@version)
      raise "Cipher with version:#{@version} not found in any of the configured Symmetric::Encryption ciphers" unless @cipher
      @stream_cipher = @cipher.send(:openssl_cipher, :decrypt)

      # First call to #update should return an empty string anyway
      @read_buffer << @stream_cipher.update(buf)
      @read_buffer << @stream_cipher.final if @ios.eof?
    end

    # Returns whether the stream being read is compressed
    #
    # Should be called before any reads are performed to determine if the file or
    # stream is compressed.
    #
    # Returns true when the header is present in the stream and it is compressed
    # Returns false when the header is present in the stream and it is not compressed
    # Returns nil when the header is not present in the stream
    #
    # Note: The file will not be decompressed automatically when compressed.
    #       To decompress the data automatically call Symmetric::Encryption.open
    def compressed?
      @compressed
    end

    # Returns the Cipher encryption version used to encrypt this file
    # Returns nil when the header was not present in the stream and no :version
    #         option was supplied
    #
    # Note: When no header is present, the version is set to the one supplied
    #       in the options
    def version
      @version
    end

    # Close the IO Stream
    #
    # Note: Also closes the passed in io stream or file
    #
    # It is recommended to call Symmetric::EncryptedStream.open or Symmetric::EncryptedStream.io
    # rather than creating an instance of Symmetric::EncryptedStream directly to
    # ensure that the encrypted stream is closed before the stream itself is closed
    def close(close_child_stream = true)
      @ios.close if close_child_stream
    end

    # Read from the stream and return the decrypted data
    # See IOS#read
    #
    # Reads at most length bytes from the I/O stream, or to the end of file if
    # length is omitted or is nil. length must be a non-negative integer or nil.
    #
    # At end of file, it returns nil or "" depending on length.
    def read(length=nil)
      data = nil
      if length
        return '' if length == 0
        # Read length bytes
        while (@read_buffer.length < length) && !@ios.eof?
          read_block
        end
        if @read_buffer.length > length
          data = @read_buffer.slice!(0..length-1)
        else
          data = @read_buffer
          @read_buffer = ''
        end
      else
        # Capture anything already in the buffer
        data = @read_buffer
        @read_buffer = ''

        if !@ios.eof?
          # Read entire file
          buf = @ios.read || ''
          data << @stream_cipher.update(buf) if buf && buf.length > 0
          data << @stream_cipher.final
        end
      end
      data
    end

    # Reads a single decrypted line from the file up to and including the optional sep_string.
    # Returns nil on eof
    # The stream must be opened for reading or an IOError will be raised.
    def readline(sep_string = "\n")
      # Read more data until we get the sep_string
      while (index = @read_buffer.index(sep_string)).nil? && !@ios.eof?
        read_block
      end
      index ||= -1
      @read_buffer.slice!(0..index)
    end

    # ios.each(sep_string="\n") {|line| block } => ios
    # ios.each_line(sep_string="\n") {|line| block } => ios
    # Executes the block for every line in ios, where lines are separated by sep_string.
    # ios must be opened for reading or an IOError will be raised.
    def each_line(sep_string = "\n")
      while !eof?
        yield readline(sep_string)
      end
      self
    end

    alias_method :each, :each_line

    # Returns whether the end of file has been reached for this stream
    def eof?
      (@read_buffer.size == 0) && @ios.eof?
    end

    private

    # Read a block of data and append the decrypted data in the read buffer
    def read_block
      buf = @ios.read(@buffer_size)
      @read_buffer << @stream_cipher.update(buf) if buf && buf.length > 0
      @read_buffer << @stream_cipher.final if @ios.eof?
    end

  end
end