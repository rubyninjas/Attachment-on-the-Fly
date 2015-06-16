Paperclip::Attachment.class_eval do
  require 'fileutils'
  require 'tempfile'
 
  module S3ConvertorMethods
    private

    def root_path
      # TODO FIXME: we should not rely on Rails as paperclip may be used without it
      File.join(Rails.root, 'public', 'system')
    end

    def path_to_file
      path = File.dirname(self.path)
      path = File.join(root_path, path)
      path = path + '/' unless path.end_with?('/')
      path
    end
  
    def asked_file_exist?
      request_webpage(@new_file_url).code.to_i == 200
    end

    def original_file_exist?
      request_webpage(self.url).code.to_i == 200
    end
  
    def request_webpage url_path
      uri = URI(url_path)
      request = Net::HTTP.new(uri.host)
      request.request_head(uri.path)
    end
    
    def source
      "amazon s3"
    end

    def convert_file!
      download_file
      super
      upload_converted_file
      remove_local_files
    end

    def remove_local_files
      File.delete(@new_file_name)
      File.delete(original)
    end

    def download_file
      uri = URI(self.url)
      response = Net::HTTP.get_response(uri)
      FileUtils.mkdir_p(path_to_file)
      File.open(original, 'wb'){|f| f.write(response.body)}
    end

    def upload_converted_file
      bucket  = self.s3_bucket
      key     = @new_file_name.gsub(/^#{root_path.to_s}\//, '')
      # another option to get a key here: File.join(File.dirname(self.path), File.basename(@new_file_name)).gsub(/^\//, '')
      stream  = File.open(@new_file_name, 'rb')
      bucket.objects[key].write(stream, :acl => :public_read)
    end
  end

  module FilesystemConvertorMethods
    private

    def path_to_file
      path = File.dirname(self.path)
      path = path + '/' unless path.end_with?('/')
      path
    end
    
    def asked_file_exist?
      File.exist?(@new_file_name)
    end
    
    def original_file_exist?
      File.exist?(original)
    end

    def source
      "filesystem"
    end

  end

  # NOTE: this works with ruby 1.9.2+
  # see https://robots.thoughtbot.com/always-define-respond-to-missing-when-overriding
  def respond_to_missing?(method, *)
    method.match(/^(cls|s)_[0-9]+_[0-9]+$/) or
    method.match(/^(cls|s)_[0-9]+_(width|height|both)$/) or
    method.match(/^(cls|s)[0-9]+$/)
  end

  def method_missing(symbol , *args, &block )
    # We are looking for methods with S_[number]_[number]_(width | height | proportion)
    # Width and Height
    # Check to see if file exists, if so return string
    # if not generate image and return string to file
    parameters = args.shift
    parameters ||= {}

    if symbol.to_s.match(/^(cls|s)_[0-9]+_[0-9]+$/)
      values = symbol.to_s.split("_")
      width = values[1].to_i
      height = values[2].to_i
      generate_image("both", width, height, parameters)
    elsif symbol.to_s.match(/^(cls|s)_[0-9]+_(width|height|both)$/)
      values = symbol.to_s.split("_")
      size = values[1].to_i
      kind = values[2]
      generate_image(kind, size, size, parameters)
    elsif symbol.to_s.match(/^(cls|s)[0-9]+$/)
      values = symbol.to_s.split("s")
      size = values[1].to_i
      kind = "width"
      generate_image(kind, size, size, parameters)
    else
      # if our method string does not match, we kick things back up to super ... this keeps ActiveRecord chugging along happily
      super
    end
  end

  private

  def generate_image(kind, width = 0, height = 0, parameters = {})
    @kind, @width, @height, @parameters = kind, width, height, parameters
    
    extend_appropriate_storage_methods
    
    @quality, @extension_colorspace     = parse_parameters
    @new_file_name, @new_file_url       = obtain_filenames
    
    return @new_file_url if asked_file_exist?
    return missing_path  unless original_file_exist?

    convert_file!

    return @new_file_url
  end

  def convert_file!
    execute_command! convertation_command
  end

  def execute_command! command
    `#{command}`
    if ($? != 0)
      raise AttachmentOnTheFlyError.new("Execution of convert failed. Please set path in Paperclip.options[:command_path] or ensure that file permissions are correct. Failed trying to do: #{command}")
    end
  end

  def convert_command_path
    if Paperclip.options[:command_path]
      Paperclip.options[:command_path] + "/"
    else
      ""
    end
  end

  def colorspace_opt
    colorspace = @parameters[:colorspace] || Paperclip.options[:colorspace]
    "-colorspace #{colorspace}" if colorspace
  end

  def convertation_command
    base_command = "#{convert_command_path}convert #{colorspace_opt} -strip -geometry"

    variative_part =
      case @kind
      when "height" then  "x#{@height}"
      when "width"  then  "#{@width}"
      when "both"   then  "#{@width}x#{@height}"
      end

    base_command + " " + variative_part + " -quality #{@quality} -sharpen 1 '#{original}' '#{@new_file_name}' 2>&1 > /dev/null"
  end

  def original_extension
    File.extname(self.path).delete('.')
  end

  def obtain_filenames
    prefix =
      case @kind 
      when "height"
        "S_" + @height.to_s + "_HEIGHT_"
      when "width"
        @width = @height
        "S_" + @height.to_s + "_WIDTH_"
      when "both"
        "S_" + @width.to_s + "_" + @height.to_s + "_"
      end

    presuffix = @parameters.slice(:extension, :colorspace).map{|k,v| "#{k}_#{v}" }.join('___') + "_q_#{@quality}_"
    prefix    = "#{prefix}#{presuffix}_"
    prefix    = "#{prefix}#{Paperclip.options[:version_prefix]}_" if Paperclip.options[:version_prefix]
    
    base_name = File.basename(self.path, File.extname(self.path))
    
    new_extension =
      if original_extension != extension && has_alpha?(original)
        # Converting extension with alpha channel is problematic.
        # Fall back to original extension.
        Paperclip.log("Ignoring extension parameter because original file is transparent")
        original_extension
      else
        extension
      end

    newfilename   = path_to_file + prefix + base_name + '.' + new_extension
    new_path      = url_path + "/" + prefix + base_name + '.' + new_extension
    
    return newfilename, new_path
  end

  def original
    path_to_file + self.original_filename
  end

  def original_extension
    File.extname(self.path).delete('.')
  end

  def extension
    @parameters[:extension] || original_extension
  end

  def parse_parameters
    @parameters.symbolize_keys!
    @parameters.slice!(:extension, :quality, :colorspace)
    [:extension, :quality].each do |opt|
      @parameters.reverse_merge!({opt => Paperclip.options[opt]}) if Paperclip.options[opt]
    end

    quality     = @parameters[:quality] || 100
    extension   = @parameters[:extension] || original_extension
    colorspace  = @parameters[:colorspace] || Paperclip.options[:colorspace]
   
    return quality, extension, colorspace
  end
  
  def url_path
    url_arr = self.url.split("/")
    url_file_name = url_arr.pop
    url_arr.join("/")
  end
  
  def has_alpha? image
    identify_command_path = (Paperclip.options[:identify_command_path] ? Paperclip.options[:identify_command_path] + "/" : "")
    # http://stackoverflow.com/questions/2581469/detect-alpha-channel-with-imagemagick
    command = "#{identify_command_path}identify -format '%[channels]' '#{image}'"
    result = `#{command}`
    if ($? != 0)
      raise AttachmentOnTheFlyError.new("Execution of identify failed. Please set path in Paperclip.options[:identify_command_path] or ensure that file permissions are correct. Failed trying to do: #{command}")
    end
    result && result.chomp == "rgba"
  end

  def missing_path
    if Paperclip.options[:whiny]
      raise AttachmentOnTheFlyError.new("Original asset could not be read from #{source} at #{original}")
    else
      Paperclip.log("Original asset could not be read from #{source} at #{original}")
      if Paperclip.options[:missing_image_path]
        return Paperclip.options[:missing_image_path]
      else
        Paperclip.log("Please configure Paperclip.options[:missing_image_path] to prevent return of broken image path")
        return @new_file_name
      end
    end
  end

  def extend_appropriate_storage_methods
    storage = (self.instance_variable_get("@options")|| {})[:storage]
    case storage
    when :s3
      extend S3ConvertorMethods 
    when :filesystem
      extend FilesystemConvertorMethods
    else
      raise AttachmentOnTheFlyError.new("Supported storages are: S3 & filesystem only.")
    end
  end

end

class AttachmentOnTheFlyError < StandardError; end
