require_relative 'my_model'

puts RUBY_VERSION

class ToSClass
    def to_s
#        "#{self.class.name} to_s called"
        nil
    end
end
class InspectClass
    def inspect
        "#{self.class.name} inspect called"
    end
end
class BothClass
    def inspect
        "#{self.class.name} inspect called"
    end
    def to_s
        "#{self.class.name} to_s called"
    end
end

c1 = ToSClass.new
puts "x=" + c1.inspect
puts "x=" + c1.to_s
c1 = InspectClass.new
puts c1.inspect
puts c1.to_s
c1 = BothClass.new
puts c1.inspect
puts c1.to_s

a = []
afirst = a.first
puts 'afirst=' + afirst.inspect

p = nil
puts 'p=' + p.inspect.to_s
puts "p=" + p.inspect

p = MyModel.new
puts 'p=' + p.inspect.to_s
puts 'p=' + p.to_s
puts "p=" + p.inspect
