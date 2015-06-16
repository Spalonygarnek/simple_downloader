require "simple_downloader/version"
require 'active_support'
require 'retryable'
require 'net/sftp'
require 'net/ssh'


module SimpleDownloader

  class Storage
    attr_accessor :protocol
    attr_accessor :server
    attr_accessor :port
    attr_accessor :user
    attr_accessor :password
    attr_accessor :retry_attempts
    attr_accessor :retry_timeout
    attr_accessor :retry_timeout_when_server_down
    attr_accessor :connection

    def initialize(
        protocol = raise('Protocol is required'),
        server = raise('Server is required'),
        opts = {}
    )

      @protocol = protocol.to_s.downcase
      supported_protocols = ['sftp']
      raise('Unsupported protocol') unless supported_protocols.include? @protocol
      @server = server.to_s

      required_options = {
          'sftp' => [:user]
      }


      case @protocol
        when 'sftp'
          default_options = {port: 22, retry_attempts: 3, retry_timeout: 10, retry_timeout_when_server_down: 180}

        else
          default_options = {retry_attempts: 3, retry_timeout: 10, retry_timeout_when_server_down: 180}
      end
      # merge options
      options = default_options.update opts


      raise("One or required parameters missing (#{required_options[@protocol].join(', ')})") if options.keys & required_options[@protocol] == []

      @user = options[:user]
      @password = options[:password]
      @port = options[:port]
      @retry_attempts = options[:retry_attempts]
      @retry_timeout = options[:retry_timeout]
      @retry_timeout_when_server_down = options[:retry_timeout_when_server_down]
      @connection = nil

    end

    def connect
      result = nil
      Retryable.retryable(:tries => self.retry_attempts, :matching => /connection closed by remote host/, :sleep => self.retry_timeout) do
        Retryable.retryable(:tries => self.retry_attempts, :matching => /getaddrinfo: Name or service not known/, :sleep => self.retry_timeout_when_server_down) do
          case self.protocol
            when 'sftp'
              # Connecting using public/private keys if no password
              self.password != nil ?
                  options = {:password => self.password, :port => self.port} :
                  options = {:port => self.port}
              # create new connection
              session = Net::SSH.start(self.server, self.user, options)
              self.connection = Net::SFTP::Session.new(session).connect!
              self.connection.state == :open ? result = true : result = false
            else
              raise "Unsupported protocol #{self.protocol}"
          end
        end
      end
      result
    end

    def disconnect
      self.connection.close_channel unless self.connection.closed?
      self.connection = nil
    end

    def download_file(remote_file, opts = {})
      raise 'Please specify Download Directory' if remote_file.download_dir == nil
      if opts[:rename] != nil
        download_path_with_rename_opts = File.dirname(remote_file.download_path) + '/' + opts[:rename]
      else
        download_path_with_rename_opts = remote_file.download_path
      end
      if opts[:overwrite] != nil
        overwrite = opts[:overwrite]
      else
        overwrite = remote_file.overwrite
      end
      case self.protocol
        when 'sftp'
          # use existing connection
          self.connect if self.connection == nil
          sftp = self.connection
          check_remote_existence!(remote_file)
          # if remote file was found...
          if remote_file.exist
            # check file with the same name on the local machine
            remote_file.local_file_exist = File.file?(download_path_with_rename_opts)
            if remote_file.local_file_exist
              if overwrite
                FileUtils.rm download_path_with_rename_opts
              else
                raise 'File cannot be downloaded. Local file with the same name exists'
              end
            end

            remote_file_content = sftp.download!(remote_file.path)
            result_file = File.open(download_path_with_rename_opts, 'wb')
            result_file.print remote_file_content
            result_file.close
            remote_file.downloaded = true

          else
            raise "There is no file to download #{remote_file.path}"
          end
        else
          raise "Unsupported protocol #{self.protocol}"
      end
      remote_file
    end

    def upload_file(local_file = raise("local_file is required"), opts = {})
      raise 'Please specify upload directory' if local_file.upload_dir == nil
      if opts[:rename] != nil
        upload_path_with_rename_opts = File.dirname(local_file.upload_path) + '/' + opts[:rename]
      else
        upload_path_with_rename_opts = local_file.upload_path
      end
      if opts[:overwrite] != nil
        overwrite = opts[:overwrite]
      else
        overwrite = local_file.overwrite
      end
      case self.protocol
        when 'sftp'
          # Check local file existence
          if File.file?(local_file.path)
            local_file.mtime= Time.at(File.mtime(local_file.path))
            # use existing connection
            self.connect if self.connection == nil
            sftp = self.connection
            remote_file = RemoteFile.new(upload_path_with_rename_opts)
            local_file.remote_file_exist= check_remote_existence!(remote_file).exist
            if remote_file.exist
              if overwrite
                sftp.remove!(upload_path_with_rename_opts)
              else
                raise 'File cannot be uploaded because remote file with the same name exists'
              end
            end
            sftp.upload!(local_file.path, upload_path_with_rename_opts)
            # save information about uploaded file
            local_file.uploaded = true
          else
            local_file.exist = false
            raise "There is no such file #{local_file.path}"
          end
        else
          raise "Unsupported protocol #{self.protocol}"
      end

      local_file
    end

    def check_remote_existence!(remote_file = raise('remote_file parameter is required'))
      case self.protocol
        when 'sftp'
          # connect if not connected
          self.connect if self.connection == nil
          sftp = self.connection
          # Search remote file by its name pattern
          found_on_remote = self.glob_remote_files(remote_file.dir, remote_file.name).first
          if found_on_remote == nil
            remote_file.exist = false
          else
            remote_file.path = found_on_remote.path
            remote_file.exist = found_on_remote.exist
            remote_file.mtime = found_on_remote.mtime
          end

        else
          raise "Unsupported protocol"
      end
      remote_file
    end

    def move_remote_file!(remote_file = raise("remote_file_object is required"), new_directory = raise("new_directory is required"), opts = {})
      # we don't use RemoteFile rename and overwrite attributes while moving file!!!
      if opts[:rename] != nil
        destination_path = new_directory + '/' + opts[:rename]
      else
        destination_path = new_directory + '/' + remote_file.name
      end
      if opts[:overwrite] != nil
        overwrite = opts[:overwrite]
      else
        overwrite = false
      end

      # gsub last '/' symbol
      new_directory.gsub!(/\/$/, '')

      case self.protocol
        when 'sftp'
          # use existing connection
          self.connect if self.connection == nil
          sftp = self.connection
          # found remote file to process
          check_remote_existence!(remote_file)
          if remote_file.exist

            # check if file with the same name exists
            if check_remote_existence!(RemoteFile.new(destination_path)).exist
              if overwrite
                sftp.remove!(destination_path)
                code = sftp.rename!(remote_file.path, destination_path).code
                raise "Error while file rename: code #{code}" if code != 0
              end
            else
              code = sftp.rename!(remote_file.path, destination_path).code
              raise "Error while file rename: code #{code}" if code != 0
            end
            # update path
            remote_file.path = destination_path
            check_remote_existence! remote_file
          else
            remote_file.exist= false
            raise "There is no such file #{remote_file.path}"
          end
        else
          raise "Unsupported protocol #{self.protocol}"
      end

      remote_file
    end

    def glob_remote_files(remote_directory, remote_file_name = nil, count = 1, silent = true)
      remote_directory.gsub!(/\/$/, '')
      case remote_file_name
        when NilClass
          file_pattern = '*'
        when String
          file_pattern = remote_file_name
        else
          raise 'Invalid remote file name parameter'
      end


      # use existing connection
      self.connect if self.connection == nil
      sftp = self.connection

      begin
        files = sftp.dir.[](remote_directory, file_pattern).select {|f| !f.directory?}.sort_by { |file| file.attributes.mtime }.reverse
        raise FileNotFound.new("File was not found") if files == []
      rescue FileNotFound, Net::SFTP::StatusException => e
        puts "WARNING!!!:#{e.description}. File pattern: '#{remote_directory + '/' + file_pattern}'" unless silent
      end

      found_files = []

      if count.class == Fixnum
        files = files.first(count)
      end

      files.each do |file|
        rf = RemoteFile.new(remote_directory + '/' + file.name)
        rf.mtime = Time.at(file.attributes.mtime)
        found_files << rf
      end
      found_files
    end
  end

  class BaseFile

    # =========================================== ACCESSORS start ============================================================
    attr_reader :path
    def path=(path)
      @path = path.gsub(/\/$/, '')
      @name = File.basename @path
      @dir = File.dirname @path
      @dir = '.' if @dir == @name
      self
    end
    attr_reader :dir
    attr_reader :name
    attr_accessor :exist
    attr_reader :mtime
    def mtime=(value)
      raise 'Wrong param type' if value.class != Time
      @mtime = value
      self.exist = true
      self
    end
    attr_reader :will_rename
    def will_rename=(value)
      if value == false
        @will_rename = false
      else
        self.desired_name = value
        @will_rename = true
      end
      self
    end
    def desired_name
      result = nil
      if self.will_rename
        result = @desired_name
      else
        result = @name
      end
      raise 'Rename result is nil' if result == nil
      result
    end
    def desired_name=(name)
      raise 'Wrong param type' if name.class != String
      @desired_name = File.basename name
      self
    end
    attr_accessor :overwrite

    # =========================================== ACCESSORS end ============================================================

    def initialize(path =  raise('Path is required field'), overwrite = false, rename = false )
      @name = nil
      @dir =  nil
      self.path = path
      @mtime = nil
      @exist = nil
      @desired_name = File.basename path
      self.will_rename = rename
      @overwrite = overwrite

    end

  end

  class LocalFile < BaseFile
    attr_accessor :upload_dir
    attr_accessor :uploaded
    attr_accessor :remote_file_exist

    def initialize(path =  raise('Path is required field'), upload_dir = nil, overwrite = false, rename = false    )
      super(path, overwrite, rename)
      @upload_dir = upload_dir
      @uploaded = false
      @remote_file_exist = nil
    end

    def upload_path
      self.upload_dir + '/' + self.desired_name
    end
  end

  class RemoteFile < BaseFile

    # =========================================== ACCESSORS start ============================================================
    attr_reader :download_dir
    def download_dir=(path)
      @download_dir = path.gsub(/\/$/, '')
    end
    attr_accessor :downloaded
    attr_accessor :local_file_exist

    # =========================================== ACCESSORS end ============================================================


    def initialize(path =  raise('Path is required field'), download_dir = nil, overwrite = false, rename = false )
      super(path, overwrite, rename)
      @download_dir = download_dir
      @downloaded = false
      @local_file_exist = nil
    end

    def download_path
      self.download_dir + '/' + self.desired_name
    end

  end

  class FileNotFound < StandardError
    attr_reader :description

    def initialize(description)
      @description = description
    end
  end

end