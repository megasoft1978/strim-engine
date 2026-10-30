# Trusted minitest runner (grader-owned, read-only to the sandbox).
# argv: <nonce-fd> <result-fd> <entry-file>. Real minitest is loaded before ./lib or ./test
# can shadow anything; autorun is disabled and results are recorded by a reporter.
require 'json'
nonce_fd = ARGV.shift.to_i
chan_fd = ARGV.shift.to_i
entry = ARGV.shift
nonce_io = IO.for_fd(nonce_fd, 'r')
nonce = nonce_io.read.strip
nonce_io.close
chan = IO.for_fd(chan_fd, 'w', autoclose: false)
chan.close_on_exec = true
chan.sync = true
emit = lambda do |record|
  chan.syswrite(nonce + ' ' + JSON.generate(record) + "\n")
end

require 'minitest'
Minitest.singleton_class.send(:define_method, :autorun) { nil }
require 'minitest/autorun'
class StrimReporter < Minitest::AbstractReporter
  attr_reader :total, :ok

  def initialize(emit)
    super()
    @emit = emit
    @total = 0
    @ok = true
  end

  def record(result)
    @total += 1
    clean = result.passed? && !result.skipped?
    @ok = false unless clean
    @emit.call(k: clean ? 'pass' : 'fail', n: "#{result.klass}##{result.name}")
  end
end

Minitest.seed = 0
reporter = Minitest::CompositeReporter.new
mine = StrimReporter.new(emit)
reporter << mine
# Cheap hardening: no mutation of the reporter/result classes by agent code.
[StrimReporter, Minitest::Result, Minitest::Runnable].each(&:freeze)
$LOAD_PATH.unshift(File.join(Dir.pwd, 'test'), File.join(Dir.pwd, 'lib'))
load File.expand_path(entry)
reporter.start
Minitest.__run(reporter, { seed: 0 })
ok = mine.ok && mine.total > 0
emit.call(k: 'end', total: mine.total, ok: ok)
exit!(ok ? 0 : 1)
