require "simple_downloader/version"
require 'active_support'
require 'retryable'
require 'net/sftp'
require 'net/ssh'
require 'net/ftp'


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
    attr_accessor :keys

    def initialize(
        protocol = raise('Protocol is required'),
        server = raise('Server is required'),
        opts = {}
    )

      @protocol = protocol.to_s.downcase
      supported_protocols = ['sftp', 'ftp']
      raise('Unsupported protocol') unless supported_protocols.include? @protocol
      @server = server.to_s

      required_options = {
          'sftp' => [:user]
      }


      case @protocol
        when 'sftp'
          default_options = {
              port: 22,
              retry_attempts: 3,
              retry_timeout: 10,
              retry_timeout_when_server_down: 180,
              keys: nil
          }

        else
          default_options = {
              retry_attempts: 3,
              retry_timeout: 10,
              retry_timeout_when_server_down: 180,
              keys: nil
          }
      end
      # merge options
      options = default_options.update opts


      raise("One of required parameters missing (#{required_options[@protocol].join(', ')})") if required_options[@protocol] == nil ? false : (options.keys & required_options[@protocol]) == []

      @user = options[:user]
      @password = options[:password]
      @port = options[:port]
      @retry_attempts = options[:retry_attempts]
      @retry_timeout = options[:retry_timeout]
      @retry_timeout_when_server_down = options[:retry_timeout_when_server_down]
      @connection = nil
      @keys = options[:keys]

    end

    def connect
      result = nil
      Retryable.retryable(:tries => self.retry_attempts, :matching => /connection closed by remote host/, :sleep => self.retry_timeout) do
        Retryable.retryable(:tries => self.retry_attempts, :matching => /getaddrinfo: Name or service not known/, :sleep => self.retry_timeout_when_server_down) do
          Retryable.retryable(:tries => self.retry_attempts, :on => [Errno::ETIMEDOUT], :sleep => self.retry_timeout_when_server_down) do
            case self.protocol
              when 'sftp'
                # Connecting using public/private keys if no password
                options = {:port => self.port} # :keys_only => true, :timeout => 1
                options[:verbose] = :debug if ENV['DEBUG'] == 'true'
                options[:password] = self.password if self.password != nil
                options[:keys] = self.keys if self.keys != nil
                # create new connection
                # todo Implement error when cannot connect for a long time
                session = Net::SSH.start(self.server, self.user, options)
                self.connection = Net::SFTP::Session.new(session).connect!
                self.connection.state == :open ? result = true : result = false

              when 'ftp'
                require 'net/ftp'
                # create new connection
                user = self.user if self.user != nil
                password = self.password if self.password != nil
                params = [self.server, user, password]
                self.connection = Net::FTP.open(*params)
                self.connection.debug_mode=true if ENV['DEBUG'] == 'true'
                self.connection.passive = true

                self.connection.closed? ? result = false : result = true

              else
                raise "Unsupported protocol #{self.protocol}"
            end
          end
        end
      end
      result
    end

    def disconnect
      case self.protocol
        when 'sftp'
          self.connection.close_channel unless self.connection.closed?
          self.connection = nil
        when 'ftp'
          self.connection.close unless self.connection.closed?
          self.connection = nil
        else
          raise "Unsupported protocol #{self.protocol}"
      end if self.connection != nil
    end

    def download_file(remote_file, opts = {})
      raise 'Please specify Download Directory' if remote_file.download_dir == nil
      self.check_remote_existence!(remote_file) if remote_file.exist == nil

      # manage options
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

      # use existing connection or connect
      self.connect if self.connection == nil
      sftp = self.connection

      # check if file exists
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
        downloaded_to_file_path = download_from_remote(sftp, remote_file.path, download_path_with_rename_opts)
        if downloaded_to_file_path
          remote_file.downloaded = true
          remote_file.download_dir = File.dirname downloaded_to_file_path
        end
      else
        raise "There is no file to download #{remote_file.path}"
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

      if File.file?(local_file.path)
        local_file.mtime= Time.at(File.mtime(local_file.path))
        # use existing connection
        self.connect if self.connection == nil
        session = self.connection
        remote_file = RemoteFile.new(upload_path_with_rename_opts)
        local_file.remote_file_exist= check_remote_existence!(remote_file).exist

        if remote_file.exist
          if overwrite
            delete_remote_file(session, upload_path_with_rename_opts)
          else
            raise 'File cannot be uploaded because remote file with the same name exists'
          end
        end

        # creating directories recursively
        remote_mkdir_p(session, File.dirname(upload_path_with_rename_opts))
        upload_to_remote(session, local_file.path, upload_path_with_rename_opts)
        # save information about uploaded file
        local_file.uploaded = true
      else
        local_file.exist = false
        raise "There is no such file #{local_file.path}"
      end
      local_file
    end

    def check_remote_existence!(file_object = raise('remote_file parameter is required'))
      # todo check if folder was found or file
      # connect if not connected
      self.connect if self.connection == nil
      # Search remote file by its name pattern
      if file_object.class == RemoteFile
        found_on_remote = self.glob_remote_files(file_object.dir, file_object.name).first
        if found_on_remote == nil
          file_object.exist = false
        else
          file_object.path = found_on_remote.path
          file_object.exist = found_on_remote.exist
          file_object.mtime = found_on_remote.mtime
        end
      elsif file_object.class == LocalFile
        found_on_remote = self.glob_remote_files(file_object.upload_dir, file_object.desired_name).first
        if found_on_remote == nil
          file_object.exist = false
        else
          file_object.remote_file_exist = found_on_remote.exist
        end
      else
        raise "Unsupported file object"
      end
      unless file_object.exist
        if check_folder_exist(self.connection, file_object.path)
          file_object.is_dir = true
        end
      end
      file_object
    end

    def move_remote_file!(remote_file = raise("remote_file_object is required"), new_directory = raise("new_directory is required"), opts = {})
      # we don't use RemoteFile rename and overwrite attributes while moving file!!!

      self.check_remote_existence!(remote_file) if remote_file.exist == nil

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

      # use existing connection
      self.connect if self.connection == nil
      connection = self.connection
      # found remote file to process
      check_remote_existence!(remote_file)
      if remote_file.exist

        # check if file with the same name exists
        if check_remote_existence!(RemoteFile.new(destination_path)).exist
          if overwrite
            delete_remote_file(connection, destination_path)
            rename_remote_file(connection, remote_file.path, destination_path)
          end
        else
          rename_remote_file(connection, remote_file.path, destination_path)
        end
        # update path
        remote_file.path = destination_path
        check_remote_existence! remote_file
      else
        remote_file.exist= false
        raise "There is no such file #{remote_file.path}"
      end
      remote_file
    end

    def glob_remote_files(remote_directory, remote_file_name = nil, count = 1)
      self.glob_remote(:file, remote_directory, remote_file_name, count)
    end

    def glob_remote_dirs(remote_directory, remote_file_name = nil, count = 1)
      self.glob_remote(:dir, remote_directory, remote_file_name, count)
    end

    def remove_remote_file(remote_file = raise('Remote file required'), skip_if_not_exist = false)
      # use existing connection
      self.connect if self.connection == nil
      connection = self.connection

      self.check_remote_existence!(remote_file) if remote_file.exist == nil

      if remote_file.is_dir
        child_files = self.glob_remote_files(remote_file.path, '**/*', :all)
        child_files.each { |c|
          delete_remote_file(connection, c.path)
        }
        child_dirs = self.glob_remote_dirs(remote_file.path, '**/*', :all).sort_by { |a| a.path.length }.reverse
        child_dirs.each { |dir|
          delete_remote_dir(connection, dir.path)
        }
        connection.rmdir! remote_file.path
        remote_file.exist = false
      else
        check_remote_existence!(remote_file)
        # if remote file was found...
        if remote_file.exist
          delete_remote_file(connection, remote_file.path)
          remote_file.exist = false
        else
          message = "There is no file to remove #{remote_file.path}"
          puts message
          raise message unless skip_if_not_exist
        end
      end
      remote_file
    end

    def glob_remote(type, remote_directory, remote_file_name = nil, count = 1)
      remote_directory.gsub!(/\/$/, '')
      case remote_file_name
        when NilClass
          file_pattern = '*'
        when String
          file_pattern = remote_file_name
        else
          raise 'Invalid remote file name parameter'
      end

      case self.protocol
        when 'sftp'
          # use existing connection
          self.connect if self.connection == nil
          sftp = self.connection
          files = nil
          begin
            files = sftp.dir.[](remote_directory, file_pattern).sort_by { |file| file.attributes.mtime }.reverse.select { |f|
              if type == :file
                !f.directory?
              elsif type == :dir
                f.directory?
              else
                raise "Incorrect type"
              end
            }
            raise FileNotFound.new("File was not found") if files == []
          rescue FileNotFound, Net::SFTP::StatusException => e
            puts "WARNING!!!:#{e.description}. File pattern: '#{remote_directory + '/' + file_pattern}'"
          end
          found_files = []

          if files != nil
            if count.class == Fixnum
              files = files.first(count)
            end
            files.each do |file|
              rf = RemoteFile.new(remote_directory + '/' + file.name)
              rf.mtime = Time.at(file.attributes.mtime)
              rf.is_dir = true if type == :dir
              found_files << rf
            end
          end

        when 'ftp'
          # use existing connection
          self.connect if self.connection == nil
          ftp = self.connection
          files = nil
          begin
            files = ftp.nlst(remote_directory + '/' + file_pattern).select { |f|
              result = nil
              if type == :file
                begin
                  result = ftp.mtime(f)
                rescue
                  next
                end
              elsif type == :dir
                begin
                  result = false if ftp.mtime(f)
                rescue
                  result = true
                end
              end
              result
            }
            files = files.sort_by { |f| ftp.mtime(f) }.reverse if type == :file
            raise FileNotFound.new("File was not found") if files == []
          rescue FileNotFound, Net::SFTP::StatusException => e
            puts "WARNING!!!:#{e.description}. File pattern: '#{remote_directory + '/' + file_pattern}'"
          end
          found_files = []

          if files != nil
            if count.class == Fixnum
              files = files.first(count)
            end
            files.each do |file|
              rf = RemoteFile.new(file)
              data = ftp.dir(remote_directory).find { |s| s.include?(File.basename(file)) }.split(' ')
              rf.mtime = Time.parse("#{data[6]} #{data[5]} #{data[7]}")
              rf.is_dir = true if type == :dir
              found_files << rf
            end
          end

        else
          raise "Unsupported protocol #{self.protocol}"
      end

      found_files
    end

    private
    def check_folder_exist(connection, dir)
      result = nil

      if connection.class == Net::FTP
        puts 'check_folder_exist for FTP'
        begin
          connection.chdir(dir)
          result = true
        rescue Net::FTPPermError => e
          if e.to_s.strip == "550 Failed to change directory."
            puts "Folder doesn't exist"
            result = false
          else
            raise Net::FTPPermError, e.to_s
          end
        end
      elsif connection.class == Net::SFTP::Session
        begin
          result = connection.dir.entries(File.dirname(dir)).map { |i| i.name }.include?(File.basename(dir))
        rescue Net::SFTP::StatusException => e
          if e.description == "no such file"
            puts "Folder doesn't exist"
            result = false
          else
            raise Net::SFTP::StatusException, e.description
          end
        end
      end

      result
    end

    def delete_remote_file(connection, path)
      if connection.class == Net::FTP
        begin
          connection.delete(path)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          connection.remove!(path)
        end
      end
    end

    def delete_remote_dir(connection, path)
      if connection.class == Net::FTP
        begin
          connection.rmdir(path)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          connection.rmdir!(path)
        end
      end
    end

    def remote_mkdir(connection, path)
      if connection.class == Net::FTP
        begin
          connection.mkdir(path)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          connection.mkdir!(path)
        rescue Net::SFTP::StatusException => e
          puts "#{path} folder cannot be created: #{e.description}"
        end
      end
    end

    def remote_mkdir_p(connection, path)
      splitted_directory = path.split('/').drop(1).map { |i| '/' + i }
      smart_dir = ''
      splitted_directory.each { |part|
        smart_dir += part
        remote_mkdir(connection, smart_dir) unless check_folder_exist(connection, smart_dir)
      }
    end

    def upload_to_remote(connection, local_file_path, remote_path)
      if connection.class == Net::FTP
        begin
          connection.storbinary("STOR " + remote_path, StringIO.new(File.open(local_file_path, "r").read), Net::FTP::DEFAULT_BLOCKSIZE)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          connection.upload!(local_file_path, remote_path)
        end
      end
    end

    def download_from_remote(connection, remote_path, local_file_path)
      # create directory if not exist
      d = File.dirname(local_file_path)
      FileUtils.mkdir_p(d) unless File.directory?(d)

      if connection.class == Net::FTP
        begin
          connection.getbinaryfile(remote_path, local_file_path)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          remote_file_content = connection.download!(remote_path)
          result_file = File.open(local_file_path, 'wb+')
          result_file.print remote_file_content
          result_file.close
        end
      end
      File.realpath(local_file_path)
    end

    def rename_remote_file(connection, current_file_path, new_file_path)
      destination_folder = File.dirname(new_file_path)
      remote_mkdir_p(connection, destination_folder) unless check_folder_exist(connection, destination_folder)

      if connection.class == Net::FTP
        begin
          connection.rename(current_file_path, new_file_path)
        end
      elsif connection.class == Net::SFTP::Session
        begin
          connection.rename!(current_file_path, new_file_path)
        end
      end
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

    def initialize(path = raise('Path is required field'), overwrite = false, rename = false)
      @name = nil
      @dir = nil
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

    def initialize(path = raise('Path is required field'), upload_dir = nil, overwrite = false, rename = false)
      super(path, overwrite, rename)
      raise "Absolute path should be used as upload folder parameter" if upload_dir[0] != '/'
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
    # hack to remove directory: create remote file and set is_dir = true
    attr_accessor :is_dir
    # =========================================== ACCESSORS end ============================================================


    def initialize(path = raise('Path is required field'), download_dir = nil, overwrite = false, rename = false)
      super(path, overwrite, rename)
      @download_dir = download_dir
      @downloaded = false
      @local_file_exist = nil
      @is_dir = false
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