# SimpleDownloader

!!!This GEM is NOT READY FOR USE!!!

This gem provides ability to download and upload files from\to remote locations (currently only `SFTP` servers are supported).
It also provides some useful options such as `rename`, `overwrite`, `retry_attempts` and `retry_timeout`.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'simple_downloader'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install simple_downloader

## Usage

**Download file:**


**Upload file:**

```ruby
file = SimpleDownloader::FileUploader.new('sftp', 'host.com', '/path/to/your/file/file.txt', {
                                                    user: 'your_login',
                                                    password: 'your_password',                                               
                                                    retry_attempts: 5,
                                                    retry_timeout: 20,
                                                    retry_timeout_when_server_down: 180
                                                })
file.upload_file('/upload/folder/', rename: 'new_name.doc', overwrite: true)
```


##Classes and Methods
####FileDownloader class
- `is_exist?` 
- `download_file`

####FileUploader
- `upload_file`


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release` to create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

1. Fork it ( https://github.com/yuri-karpovich/simple_downloader/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
