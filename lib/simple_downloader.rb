require "simple_downloader/version"
require 'active_support'
require 'retryable'
require 'net/sftp'


module SimpleDownloader

  # Base class that contains all common variables and methods for child classes.
    class FileDownloaderBase


    # @return [String, #downcase] Protocol name
    attr_accessor :protocol
    # @return [String] Server name
    attr_accessor :server
    # @return [String] Username
    attr_accessor :user
    # @return [String] Password
    attr_accessor :password
    attr_accessor :key
    # @return [true, false, nil] Shows if file exists on remote server
    attr_accessor :exist
    # @return [Date, nil] Last modified time of remote file
    attr_accessor :remote_file_time
    # @return [Fixnum] Number of attempts to upload\download file 
    attr_accessor :retry_attempts
    # @return [Fixnum] Timeout of attempt in ms
    attr_accessor :retry_timeout
    # @return [Fixnum] Timeout of attempt in ms when server is not responding
    attr_accessor :retry_timeout_when_server_down
    # @return [Fixnum] connection port. If required
    attr_accessor :port


    cattr_reader :supported_protocols
    @@supported_protocols = ['sftp']


    # Base initialize method with common variables set
    #
    # @param protocol[String, Symbol] one of supported protocols
    # @param server[String] server name
    # @option options [String] :user username
    # @option options [String] :password password
    # @option options [String] :port port
    # @option options [Symbol] :key key associated with file
    # @option options [Fixnum] :retry_attempts Number of attempts to perform operation
    # @option options [Fixnum] :retry_timeout Operation timeout
    # @option options [Fixnum] :retry_timeout_when_server_down Operation timeout when server is not responding
    def initialize(
        protocol = raise('Protocol is required'),
        server = raise('Server is required'),
        options = {port: 22, retry_attempts: 3, retry_timeout: 10, retry_timeout_when_server_down: 180}
    )


      raise('Protocol is required') if protocol.nil?
      @protocol = protocol.to_s.downcase
      raise('Unsupported protocol') unless supported_protocols.include? @protocol

      raise('Server is required') if server.nil?
      @server = server.to_s
      @port = options[:port]

      options[:user] ||= raise('User is required parameter') if ['sftp'].include? @protocol
      @user = options[:user]

      options[:password] ||= raise('Password is required parameter') if ['sftp'].include? @protocol
      @password = options[:password]

      @key = options[:key]
      @exist = nil
      @remote_file_time = nil

      @retry_attempts = options[:retry_attempts]
      @retry_timeout = options[:retry_timeout]
      @retry_timeout_when_server_down = options[:retry_timeout_when_server_down]

    end


    # *SFTP* connection for further operations
    #
    # @param remote_dir[String] path to remote directory
    # @yieldparam sftp[Net::SFTP::Session] sftp session
    def sftp_connect(remote_dir, &block)
      Retryable.retryable(:tries => self.retry_attempts, :matching => /connection closed by remote host/, :sleep => self.retry_timeout) do
        Retryable.retryable(:tries => self.retry_attempts, :matching => /getaddrinfo: Name or service not known/, :sleep => self.retry_timeout_when_server_down) do
          Net::SFTP.start(self.server, self.user, :password => self.password, :port => self.port) do |sftp|
            sftp.stat!(remote_dir) do |response|
              # Check connection for the remote folder
              if response.ok?
                yield sftp
              else
                raise "Bad response. Possible reason: directory doesn't exist"
              end
            end
          end
        end
      end
    end

    # Returns true if connection to *SFTP* server can be established
    #
    # @return [true, false]
    def sftp_ok_response?
      result = nil
      Retryable.retryable(:tries => self.retry_attempts, :matching => /connection closed by remote host/, :sleep => self.retry_timeout) do
        Retryable.retryable(:tries => self.retry_attempts, :matching => /getaddrinfo: Name or service not known/, :sleep => self.retry_timeout_when_server_down) do
          Net::SFTP.start(self.server, self.user, :password => self.password, :port => self.port) do |sftp|
            sftp.stat!('/') do |response|
              # Check connection for the remote folder
              if response.ok?
                result = true
              else
                result = false
              end
            end
          end rescue  result = false
        end
      end
      result
    end


    # Check if remote file exist on server.
    # method updates *exist* object variable
    #
    # @return [true, false]
    def is_exist?(remote_path = nil)
      result = nil
      case self.protocol
        when 'sftp'

          # Autofill remote file path from #FileDownloader properties when it is used. It not - use #remote_path param
          search_path = remote_path
          search_path = self.name_pattern if remote_path == nil rescue nil
          raise('remote_path parameter should be specified') if search_path == nil

          # Parse name pattern to file name and file path
          remote_directory = File.dirname(search_path)
          filename_pattern = File.basename(search_path)
          # Connect to sftp
          self.sftp_connect(remote_directory) { |sftp|
            # Search remote file by its name pattern
            remote_file = sftp.dir.[](remote_directory, filename_pattern).sort_by { |file| file.attributes.mtime }.reverse.first
            # If remote file was found...
            if remote_file != nil
              result = true
            else
              result = false
            end
          }
        else
          raise "Unsupported protocol"
      end
      self.exist = result
    end
  end


  # Describes the file to be downloaded from remote server
  class FileDownloader < FileDownloaderBase


    # @param [String] Filename or filename glob pattern of file to be downloaded
    attr_accessor :name_pattern
    # @param [String, nil] path where file was downloaded
    attr_accessor :local_path


    # @param protocol[String, Symbol] one of supported protocols
    # @param server[String] server name
    # @param name_pattern[String] Filename or filename glob pattern of file to be downloaded
    # @option options [String] :user username
    # @option options [String] :password password
    # @option options [Symbol] :key key associated with file
    # @option options [Fixnum] :retry_attempts Number of attempts to perform operation
    # @option options [Fixnum] :retry_timeout Operation timeout
    # @option options [Fixnum] :retry_timeout_when_server_down Operation timeout when server is not responding
    def initialize(
        protocol,
        server,
        name_pattern,
        options = {}
    )

      # Inherit parent class *initialize* method and its parameters
      super(protocol, server, options)


      @name_pattern = name_pattern
      @local_path = nil

    end




    # Download remote file.
    #
    # @param local_directory[String] path to local folder where downloaded file will be saved.
    # @option options [String, false] :rename save downloaded file with another name specified
    # @option options [String, false] :overwrite should local file be overwritten with new one?
    # @option options [String] :temp_folder temp folder where to save downloaded file.
    # @return [FileDownloader] modified object
    def download_file(local_directory = raise("local_dir is required"), options = {overwrite: false, rename: false, temp_folder: 'tmp'})
      # Parse directory path and delete unnecessary '/' symbol at the end
      local_directory[-1] == '/' ? local_dir = local_directory[0..-2] : local_dir = local_directory
      overwrite = options[:overwrite]
      rename = options[:rename]
      temp_folder = options[:temp_folder]
      # Create temp folder if it doesn't exist
      FileUtils.mkdir_p temp_folder
      # Parse remote file name (or name pattern) and directory path
      remote_directory = File.dirname(self.name_pattern)
      filename_pattern = File.basename(self.name_pattern)

      case self.protocol
        when 'sftp'
          self.sftp_connect(remote_directory) { |sftp|
            # Srach remote file
            remote_file = sftp.dir.[](remote_directory, filename_pattern).sort_by { |file| file.attributes.mtime }.reverse.first
            # if remote file was found...
            if remote_file != nil
              self.exist = true

              rename == false ? local_file_name = remote_file.name : local_file_name = FIle.basename(rename)
              local_path = local_dir + '/' + local_file_name
              file_already_exist = File.file?(local_path)

              # Overwrite local file if file already exist
              unless overwrite == false && file_already_exist
                temp_file_path = temp_folder + '/' + local_file_name
                FileUtils.rm temp_file_path if File.file?(temp_file_path)
                remote_file_content = sftp.download!(remote_directory + '/' + remote_file.name)
                temp_file = File.open(temp_file_path, 'wb')
                temp_file.print remote_file_content
                temp_file.close
                FileUtils.mv(temp_file_path, local_path, {:force => true, :verbose => true}) if temp_file_path != local_path
                remote_file_time = Time.at(remote_file.attributes.mtime)
                self.remote_file_time = remote_file_time
              end
              self.local_path = local_path

            else
              self.exist = false
            end
          }
        else
          raise "Unsupported protocol"
      end
      self
    end

  end


  # Describes the file to be uploaded to remote server
  class FileUploader < FileDownloaderBase

    # @return [String] path to uploaded file
    attr_accessor :local_path
    # @return [String] path where file shoild be uploaded
    attr_accessor :remote_path


    # @param protocol[String, Symbol] one of supported protocols
    # @param server[String] server name
    # @param local_path[String] Filename of file to be uploaded
    # @option options [String] :user username
    # @option options [String] :password password
    # @option options [Symbol] :key key associated with file
    # @option options [Fixnum] :retry_attempts Number of attempts to perform operation
    # @option options [Fixnum] :retry_timeout Operation timeout
    # @option options [Fixnum] :retry_timeout_when_server_down Operation timeout when server is not responding
    def initialize(
        protocol,
        server,
        local_path,
        options = {}
    )

      # Inherit parent class *initialize* method and its parameters
      super(protocol, server, options)

      @local_path = local_path
      @remote_path = nil

    end


    # Upload file to remote host
    #
    # @param remote_directory[String] directory on remote host where file should be uploaded
    # @option options [String, false] :rename save downloaded file with another name specified
    # @option options [String, false] :overwrite should local file be overwritten with new one?
    # @return [FileUploader] modified object
    def upload_file(remote_directory = raise("remote_dir is required"), options = {overwrite: false, rename: false})
      remote_directory[-1] == '/' ? remote_dir = remote_directory[0..-2] : remote_dir = remote_directory
      overwrite = options[:overwrite]
      rename = options[:rename]

      case self.protocol
        when 'sftp'
          self.sftp_connect(remote_dir) { |sftp|

            file_name = File.basename(self.local_path)

            rename == false ? new_file_name = file_name : new_file_name = File.basename(rename)

            remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
            remote_path = remote_dir +'/'+ new_file_name
            if remote_file != nil
              self.exist = true

              if overwrite
                sftp.remove!(remote_path)
                sftp.upload!(self.local_path, remote_path)
                remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
                remote_file_time = Time.at(remote_file.attributes.mtime)
                self.remote_file_time = remote_file_time
              end

            else
              self.exist = false
              sftp.upload!(self.local_path, remote_path)
              remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
              remote_file_time = Time.at(remote_file.attributes.mtime)
              self.remote_file_time = remote_file_time
            end
          }
        else
          raise "#{self.class}: Unsupported protocol"
      end
      self
    end
  end
end


