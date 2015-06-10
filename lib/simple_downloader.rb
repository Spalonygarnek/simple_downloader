require "simple_downloader/version"
require 'active_support'
require 'retryable'
require 'net/sftp'


module SimpleDownloader

  # Describes remote storage
  class Storage
    # @return [String, #downcase] Protocol name
    attr_accessor :protocol
    # @return [String] Server name
    attr_accessor :server
    # @return [String] Username
    attr_accessor :user
    # @return [String] Password
    attr_accessor :password
    # @return [Fixnum] Number of attempts to upload\download file
    attr_accessor :retry_attempts
    # @return [Fixnum] Timeout of attempt in ms
    attr_accessor :retry_timeout
    # @return [Fixnum] Timeout of attempt in ms when server is not responding
    attr_accessor :retry_timeout_when_server_down
    # @return [Fixnum] connection port
    attr_accessor :port

    attr_reader :supported_protocols


    # @param protocol[String, Symbol] one of supported protocols
    # @param server[String] server name
    # @option opts [String] :user username
    # @option opts [String] :password password
    # @option opts [String] :port port
    # @option opts [Fixnum] :retry_attempts Number of attempts to perform operation
    # @option opts [Fixnum] :retry_timeout Operation timeout
    # @option opts [Fixnum] :retry_timeout_when_server_down Operation timeout when server is not responding
    def initialize(
        protocol = raise('Protocol is required'),
        server = raise('Server is required'),
        opts = {}
    )
      # merge options
      default_options = {port: 22, retry_attempts: 3, retry_timeout: 10, retry_timeout_when_server_down: 180}
      options = default_options.update opts

      supported_protocols = ['sftp']
      @protocol = protocol.to_s.downcase
      raise('Unsupported protocol') unless supported_protocols.include? @protocol

      @server = server.to_s

      if ['sftp'].include? @protocol
        options[:user] ||= raise('User is required parameter')
        @user = options[:user]

        options[:password] ||= raise('Password is required parameter')
        @password = options[:password]

      end

      @port = options[:port]
      @retry_attempts = options[:retry_attempts]
      @retry_timeout = options[:retry_timeout]
      @retry_timeout_when_server_down = options[:retry_timeout_when_server_down]

    end


    # Establish connection *yield* method.
    #
    # @param optional remote_path[String] path used for verification that connection can be successfully established.
    # @yieldparam sftp[Net::SFTP::Session] sftp session
    # @return [true, false]
    # @example check that connection to the remote host can be established
    #     sftp.connect
    #     => true
    # @example use sftp connection yield
    #     self.connect(remote_directory) { |sftp|
    #     sftp.dir.[](remote_directory, filename_pattern).sort_by { |file| file.attributes.mtime }.reverse.first
    #     }
    def connect(remote_path = nil, &block)
      remote_directory = remote_path || '/'
      result = nil
      Retryable.retryable(:tries => self.retry_attempts, :matching => /connection closed by remote host/, :sleep => self.retry_timeout) do
        Retryable.retryable(:tries => self.retry_attempts, :matching => /getaddrinfo: Name or service not known/, :sleep => self.retry_timeout_when_server_down) do
          case self.protocol



          when 'sftp'
            Net::SFTP.start(self.server, self.user, :password => self.password, :port => self.port) do |sftp|
              sftp.stat!(remote_directory) do |response|
                # Check connection for the remote folder
                if response.ok?
                  yield sftp if block != nil
                  result = true
                else
                  result = false
                  puts "Bad response. Possible reason: directory doesn't exist"
                end
              end
            end



            else
              raise "Unsupported protocol #{self.protocol}"
          end
        end
      end
      result
    end


    # Download file from storage.
    #
    # @param remote_file_object[SimpleDownloader::RemoteFile] remote file object to be downloaded
    # @param local_directory[String] path to save downloads
    # @option opts [true, false] :overwrite should local file be overwritten
    # @option opts [false, String] :rename should downloaded file be renamed while saving? Specify file name if you want to rename file
    # @option opts [String] :temp_folder folder where to save temp files. Defaukt tmp folder will be created if doesn't exist
    # @return [SimpleDownloader::RemoteFile] remote file object
    def download_file(remote_file_object, local_directory,  opts = {})
      default_options = {overwrite: false, rename: false, temp_folder: 'tmp'}
      options = default_options.update opts
      # Parse directory path and delete unnecessary '/' symbol at the end
      local_directory[-1] == '/' ? local_dir = local_directory[0..-2] : local_dir = local_directory
      overwrite = options[:overwrite]
      rename = options[:rename]
      temp_folder = options[:temp_folder]
      # Create temp folder if it doesn't exist
      FileUtils.mkdir_p temp_folder
      # Parse remote file name (or name pattern) and directory path
      remote_directory = File.dirname(remote_file_object.path)
      filename_pattern = File.basename(remote_file_object.path)

      case self.protocol



        when 'sftp'
          self.connect(remote_directory) { |sftp|
            # Search remote file
            remote_file = sftp.dir.[](remote_directory, filename_pattern).sort_by { |file| file.attributes.mtime }.reverse.first
            # if remote file was found...
            if remote_file != nil
              remote_file_object.already_uploaded = true

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
                remote_file_object.remote_file_time = remote_file_time
              end
              remote_file_object.local_path = local_path

            else
              remote_file_object.already_uploaded = false
            end
          }



        else
          raise "Unsupported protocol #{self.protocol}"
      end
      remote_file_object
    end

    # Upload file to storage.
    #
    # @param local_file_object[SimpleDownloader::LocalFile] local file object to be uploaded
    # @param remote_directory[String] path to save uploads
    # @option opts [true, false] :overwrite should remote file be overwritten?
    # @option opts [false, String] :rename should remote file be renamed while saving? Specify file name if you want to rename file
    # @return [SimpleDownloader::LocalFile] local file object
    def upload_file(local_file_object = raise("local_file_object is required"), remote_directory = raise("remote_directory is required"), opts = {})
      # merge options
      default_options = {overwrite: false, rename: false}
      options = default_options.update opts

      remote_directory[-1] == '/' ? remote_dir = remote_directory[0..-2] : remote_dir = remote_directory
      overwrite = options[:overwrite]
      rename = options[:rename]

      case self.protocol



        when 'sftp'
          self.connect(remote_dir) { |sftp|

            file_name = File.basename(local_file_object.path)

            rename == false ? new_file_name = file_name : new_file_name = File.basename(rename)

            remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
            remote_path = remote_dir +'/'+ new_file_name
            if remote_file != nil
              local_file_object.remote_exist = true

              if overwrite
                sftp.remove!(remote_path)
                sftp.upload!(local_file_object.path, remote_path)
                remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
                remote_file_time = Time.at(remote_file.attributes.mtime)
                local_file_object.remote_file_time = remote_file_time
              end

            else
              local_file_object.remote_exist = false
              sftp.upload!(local_file_object.path, remote_path)
              remote_file = sftp.dir.[](remote_dir, new_file_name).sort_by { |file| file.attributes.mtime }.reverse.first
              remote_file_time = Time.at(remote_file.attributes.mtime)
              local_file_object.remote_file_time = remote_file_time
            end
            local_file_object.remote_path = remote_path
          }



        else
          raise "Unsupported protocol #{self.protocol}"
      end
      local_file_object
    end

    # Check if remote file exist on server.
    # method updates *exist* object variable
    #
    # @param remote_file[SimpleDownloader::RemoteFile] remote file object.
    #   You can use glob pattern in the remote file basename only! The remote file  dirname doesn't support glob patterns!
    # @return [true, false]
    def is_exist?(remote_file = raise('remote_file parameter is required'))
      result = nil
      case self.protocol



        when 'sftp'
          # Parse name pattern to file name and file path
          remote_directory = File.dirname(remote_file.path)
          filename_pattern = File.basename(remote_file.path)
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
      remote_file.exist = result
      result
    end
  end


  # Describes file on the local machine
  class LocalFile
    # @return [String] local file path
    attr_accessor :path
    # @return [String] path where file was uploaded
    attr_accessor :remote_path
    # @return [Date, nil] last modified time of remote file copy
    attr_accessor :remote_file_time
    # @return [true, false, nil] shows path where file was uploaded last time
    attr_accessor :remote_exist

    # @param path[String] local file path
    def initialize(path =  raise('Path is required field')    )
      @path = path
      @remote_path = nil
      @remote_file_time = nil
      @remote_exist = nil
    end
  end


  # Describes file on the remote machine
  class RemoteFile
    
    # @return [String] path OR GLOB PATTERN to find remote file. You can use Glob pattern only in file basename but not in dirname.
    attr_accessor :path
    # @return[:true, false, nil] shows if remote file already exist on server
    attr_accessor :already_uploaded
    # @return [Date, nil] last modified time of remote file
    attr_accessor :remote_file_time
    # @return [String] path where remote file was saved
    attr_accessor :local_path

    # @param path[String] path OR GLOB PATTERN to find remote file. You can use Glob pattern only in file basename but not in dirname.
    def initialize(path =  raise('Path is required field')    )
      @path = path
      @already_uploaded = nil
      @remote_file_time = nil
      @local_path = nil
    end

  end

end


