# frozen_string_literal: true
#
# Dry-run survey for migrating "MRI: foo" comments to an @MRI annotation.
# Run with JRuby (uses the JDK's javac Tree API as the Java parser):
#
#   bin/jruby mri_annotate.rb [--ruby-src ../ruby] [--diff] [--show CATEGORY[,N]] [--tsv FILE] [PATH...]
#
# It NEVER writes to the Java sources.

require 'java'
require 'optparse'
require 'json'
require 'set'

java_import 'javax.tools.ToolProvider'
java_import 'com.sun.source.util.TreeScanner'
java_import 'com.sun.source.util.Trees'

opts = { ruby_src: File.expand_path('../ruby'), diff: false, show: [], tsv: nil, samples: 6 }
OptionParser.new do |o|
  o.on('--ruby-src DIR') { |v| opts[:ruby_src] = File.expand_path(v) }
  o.on('--diff') { opts[:diff] = true }
  o.on('--show CAT') { |v| opts[:show] << v.to_sym }
  o.on('--tsv FILE') { |v| opts[:tsv] = v }
  o.on('--samples N', Integer) { |v| opts[:samples] = v }
end.parse!
roots = ARGV.empty? ? ['core/src/main/java'] : ARGV

# ---------------------------------------------------------------- CRuby index
class CRubyIndex
  SKIP = %r{/(spec|test|benchmark|tool|\.git|vendor|gems|doc|bootstraptest|sample|win32|wasm)/}
  DEFS = [
    /^([A-Za-z_]\w*)\(/,                                               # "name(" at column 0 (GNU style)
    /^(?:static|extern|RUBY_FUNC_EXPORTED|inline)\b[\w \t\*]*?[ \t\*](\w+)\([^;]*$/, # one-line decls
    /^(?!return|if|else|while|for|switch|case|typedef|#)[A-Za-z_][\w \t\*]*?[ \t\*](\w+)\([^;]*$/, # "VALUE name(args)" on one line
    /^\s*#\s*define\s+(\w+)/                                           # macros
  ].freeze

  attr_reader :table

  def initialize(dir)
    @table = Hash.new { |h, k| h[k] = [] }
    Dir.glob(File.join(dir, '**', '*.{c,h,y,inc}')).each do |f|
      next if f.match?(SKIP)
      rel = f.sub(dir + '/', '')
      File.open(f, 'rb') do |io|
        io.each_line.with_index(1) do |line, no|
          DEFS.each do |re|
            next unless (m = re.match(line))
            @table[m[1]] << [rel, no]
            break
          end
        end
      end
    end
  end

  def [](name) = @table.key?(name) ? @table[name] : nil
  def files(name) = (self[name] || []).map(&:first).uniq
end

# ------------------------------------------------------- Java comment scanner
Comment = Struct.new(:start, :end, :text, :kind, :lines)

def scan_comments(src)
  out = []
  i = 0
  n = src.length
  while i < n
    c = src[i]
    nx = src[i + 1]
    if c == '/' && nx == '/'
      j = src.index("\n", i) || n
      out << Comment.new(i, j, src[i...j], :line)
      i = j
    elsif c == '/' && nx == '*'
      j = (src.index('*/', i + 2) || n - 2) + 2
      out << Comment.new(i, j, src[i...j], src[i + 2] == '*' && src[i + 3] != '/' ? :doc : :block)
      i = j
    elsif c == '"'
      if src[i, 3] == '"""'
        i = (src.index('"""', i + 3) || n - 3) + 3
      else
        i += 1
        i += (src[i] == '\\' ? 2 : 1) while i < n && src[i] != '"' && src[i] != "\n"
        i += 1
      end
    elsif c == "'"
      i += 1
      i += (src[i] == '\\' ? 2 : 1) while i < n && src[i] != "'" && src[i] != "\n"
      i += 1
    else
      i += 1
    end
  end
  out
end

# Merge adjacent // lines (separated by a single newline + indentation) into one comment.
def merge_line_comments(src, comments)
  out = []
  comments.each do |c|
    prev = out.last
    if c.kind == :line && prev && prev.kind == :line && src[prev.end...c.start].match?(/\A\n[ \t]*\z/)
      prev.end = c.end
      prev.text = src[prev.start...c.end]
    else
      out << c
    end
  end
  out
end

def comment_body(c)
  case c.kind
  when :line
    c.text.lines.map { |l| l.sub(%r{\A\s*//+\s?}, '').rstrip }
  else
    c.text.sub(%r{\A/\*+}, '').sub(%r{\*+/\z}, '').lines.map { |l| l.sub(/\A\s*\*?\s?/, '').rstrip }
  end
end

# ----------------------------------------------------------- reference parsing
CIDENT = /\b[A-Za-z_]\w*\b/
CLIKE  = /\A(?:rb|[a-z0-9]+)_[a-z0-9_]+\z|\A[A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+\z/

# returns { names:, rest:, form: } or nil
def parse_refs(body_lines, index)
  text = body_lines.join("\n").strip
  return nil if text.empty?

  names = []
  rest = []
  form = nil

  if text.match?(/\bMRI\b\s*:?/)
    form = :mri_prefix
    text.scan(/\bMRI\b\s*:?\s*([^\n)]*)/) do |(tail)|
      toks = tail.split(/\s*(?:,|&|\band\b|\bor\b|;)\s*/)
      toks.each do |t|
        t = t.strip.sub(/[.]\z/, '')
        next if t.empty?
        if t.match?(/\A[A-Za-z_]\w*(?:\(\))?\z/) && (t.match?(CLIKE) || index[t.delete_suffix('()')])
          names << t.delete_suffix('()')
        elsif (m = t.match(/\A([A-Za-z_]\w*)(?:\(\))?\s+(.*)\z/)) && (m[1].match?(CLIKE) || index[m[1]])
          names << m[1]
          rest << m[2]
        else
          rest << t
        end
      end
    end
    # everything outside the MRI clauses counts as prose
    outside = text.gsub(/\(?\s*\bMRI\b\s*:?\s*[^\n)]*\)?/, '').strip
    rest << outside unless outside.empty?
    return nil if names.empty? && rest.empty?
    { names: names.uniq, rest: rest, form: form, whole: outside.empty? }
  else
    first = body_lines.first.to_s.strip
    m = first.match(/\A([A-Za-z_]\w*)\s*(?:[:\-]\s*(.*))?\z/) or return nil
    name = m[1]
    return nil unless name.match?(CLIKE) && (index[name] || name.start_with?('rb_'))
    prose = ([m[2].to_s] + body_lines[1..].to_a).map(&:strip).reject(&:empty?)
    { names: [name], rest: prose, form: :bare, whole: prose.empty? }
  end
end

# --------------------------------------------------------------- Java parsing
class DeclCollector < TreeScanner
  attr_reader :decls, :method_ranges

  def initialize(cu, sp)
    super()
    @cu = cu
    @sp = sp
    @decls = []
    @method_ranges = []
    @stack = []
  end

  def record(node, kind, name, annotations = [])
    s = @sp.getStartPosition(@cu, node)
    e = @sp.getEndPosition(@cu, node)
    @decls << { kind: kind, name: name.to_s, start: s, end: e, annos: annotations.map { |a| a.getAnnotationType.toString } }
    [s, e]
  end

  def visitClass(node, p)
    record(node, :class, node.getSimpleName)
    @stack.push(:class)
    super
  ensure
    @stack.pop
  end

  def visitMethod(node, p)
    s, e = record(node, node.getName.to_s == '<init>' ? :ctor : :method, node.getName, node.getModifiers.getAnnotations)
    @method_ranges << (s..e) if node.getBody
    @stack.push(:method)
    super
  ensure
    @stack.pop
  end

  def visitVariable(node, p)
    record(node, :field, node.getName, node.getModifiers.getAnnotations) if @stack.last == :class
    super
  end
end

def ws_before(src, pos)
  pos -= 1 while pos > 0 && src[pos - 1].match?(/\s/)
  pos
end

def java_files(roots)
  roots.flat_map { |r| File.directory?(r) ? Dir.glob(File.join(r, '**', '*.java')) : [r] }.sort
end

# --------------------------------------------------------------------- driver
$stderr.puts "indexing CRuby at #{opts[:ruby_src]} ..."
index = CRubyIndex.new(opts[:ruby_src])
$stderr.puts "  #{index.table.size} C identifiers"

files = java_files(roots)
$stderr.puts "parsing #{files.size} Java files with javac ..."
compiler = ToolProvider.getSystemJavaCompiler
fm = compiler.getStandardFileManager(nil, nil, nil)
task = compiler.getTask(nil, fm, ->(_) {}, ['-proc:none'], nil, fm.getJavaFileObjectsFromStrings(files))
sp = Trees.instance(task).getSourcePositions
units = task.parse.to_a

findings = []   # one per reference-bearing comment
stats = Hash.new(0)

units.each do |cu|
  path = cu.getSourceFile.toUri.getPath
  rel = path.sub(Dir.pwd + '/', '')
  src = File.read(path, encoding: 'UTF-8')
  if src.match?(/[\u{10000}-\u{10FFFF}]/)
    $stderr.puts "skip (astral chars): #{rel}"
    next
  end

  coll = DeclCollector.new(cu, sp)
  coll.scan(cu, nil)
  decls = coll.decls.sort_by { |d| d[:start] }
  comments = merge_line_comments(src, scan_comments(src))
  by_end = comments.each_with_index.to_h { |c, i| [c.end, i] }
  consumed = Set.new
  nl = []
  src.each_char.with_index { |ch, i| nl << i if ch == "\n" }
  line_of = ->(off) { nl.bsearch_index { |x| x >= off } || nl.size }.then { |f| ->(off) { f.(off) + 1 } }

  decls.each do |d|
    stats[:"decl_#{d[:kind]}"] += 1
    jm = d[:annos].any? { |a| a.end_with?('JRubyMethod') }
    stats[:jruby_method] += 1 if jm

    # find the comment immediately above the declaration
    pos = ws_before(src, d[:start])
    chain = []
    loop do
      idx = by_end[pos] or break
      c = comments[idx]
      chain.unshift(c)
      npos = ws_before(src, c.start)
      break if src[npos...c.start].count("\n") > 1 # blank line ends the chain
      pos = npos
    end
    # a declaration can only own comments no other declaration already claimed
    chain.reject! { |c| consumed.include?(c.start) }
    chain.each { |c| consumed << c.start }

    hit = nil
    chain.each do |c|
      refs = parse_refs(comment_body(c), index)
      next unless refs
      hit = [c, refs]
    end
    if jm
      stats[hit ? :jruby_method_with_ref : :jruby_method_without_ref] += 1
    end
    next unless hit
    c, refs = hit
    findings << { file: rel, line: line_of.(c.start), comment: c, refs: refs, decl: d, jm: jm,
                  gap_blank: src[c.end...d[:start]].count("\n") > 1, chain_len: chain.size, src: src }
  end

  # comments not attached to any declaration
  comments.each do |c|
    next if consumed.include?(c.start)
    refs = parse_refs(comment_body(c), index)
    refs = nil if refs && refs[:form] == :bare # bare identifiers only make sense as headers
    next unless refs
    inner = coll.method_ranges.any? { |r| r.cover?(c.start) }
    findings << { file: rel, line: line_of.(c.start), comment: c, refs: refs, decl: nil, inner: inner, src: src }
  end
end

# ------------------------------------------------------------ classification
findings.each do |f|
  r = f[:refs]
  f[:resolved] = r[:names].empty? ? nil : r[:names].all? { |n| index[n] }
  f[:unresolved_names] = r[:names].reject { |n| index[n] }
  f[:files] = r[:names].filter_map { |n| (fs = index.files(n)).size == 1 ? fs.first : nil }

  f[:category] =
    if r[:names].empty?
      :mention
    elsif f[:decl].nil?
      f[:inner] ? :inner : :orphan
    elsif false
      :qualified
    elsif r[:rest].any? && r[:whole] == false && r[:form] == :mri_prefix && r[:rest].join.length <= 40 && f[:comment].kind != :doc
      :qualified
    elsif r[:rest].any? && f[:comment].kind == :doc
      :prose
    elsif r[:rest].any?
      :qualified
    elsif r[:names].size > 1
      :multi
    else
      :clean
    end
end

def proposal(f, index)
  r = f[:refs]
  parts = r[:names].map do |n|
    fs = index.files(n)
    if fs.size == 1
      %(@MRI(value = "#{n}", file = "#{fs.first}"))
    elsif fs.empty?
      %(@MRI("#{n}") /* NOT FOUND in CRuby */)
    else
      %(@MRI("#{n}") /* ambiguous: #{fs.first(3).join(', ')} */)
    end
  end
  parts.join(' ')
end

# -------------------------------------------------------------------- report
puts '=' * 72
puts "MRI-comment -> @MRI annotation dry run  (#{files.size} files, #{units.size} parsed)"
puts '=' * 72
puts
puts 'Declarations: ' + %i[class ctor method field].map { |k| "#{k}=#{stats[:"decl_#{k}"]}" }.join('  ')
jm = stats[:jruby_method]
puts format('@JRubyMethod methods: %d  with C ref: %d (%.1f%%)  without: %d',
            jm, stats[:jruby_method_with_ref], 100.0 * stats[:jruby_method_with_ref] / [jm, 1].max,
            stats[:jruby_method_without_ref])
puts
puts "Reference-bearing comments: #{findings.size}"
puts

cats = %i[clean multi prose qualified inner orphan mention]
desc = {
  clean: 'leading comment is only one C name          -> auto-convert, delete comment',
  multi: 'leading comment is only several C names     -> auto-convert as repeatable',
  prose: 'leading javadoc: C name + prose             -> convert, keep prose (rewrite comment)',
  qualified: 'MRI: name + free text ("loop body", ...)  -> human review',
  inner: 'comment inside a method body                -> keep as comment / extract helper',
  orphan: 'comment not above any declaration           -> human review',
  mention: 'says "MRI" but names no C function         -> not a mapping (prose); ignore'
}
puts format('%-10s %6s %9s %11s   %s', 'category', 'count', 'resolved', 'unresolved', '')
cats.each do |cat|
  fs = findings.select { |f| f[:category] == cat }
  res = fs.count { |f| f[:resolved] }
  unres = fs.count { |f| f[:resolved] == false }
  puts format('%-10s %6d %9d %11d   %s', cat, fs.size, res, unres, desc[cat])
end
puts

auto = findings.select { |f| %i[clean multi prose].include?(f[:category]) }
auto_ok = auto.select { |f| f[:resolved] }
puts "Auto-convertible (clean+multi+prose): #{auto.size}; of those all names found in CRuby: #{auto_ok.size}"
uniq_file = auto_ok.count { |f| f[:files].size == f[:refs][:names].size }
puts "  ... with an unambiguous source file: #{uniq_file}"
puts "  ... attached to @JRubyMethod: #{auto.count { |f| f[:jm] }}; helpers/other: #{auto.count { |f| !f[:jm] }}"
by_kind = auto.group_by { |f| f[:decl][:kind] }.transform_values(&:size)
puts "  ... by target: #{by_kind.inspect}"
forms = findings.group_by { |f| f[:refs][:form] }.transform_values(&:size)
puts "Comment forms: #{forms.inspect}"
puts "Detached (blank line between comment and decl): #{findings.count { |f| f[:gap_blank] }}"
puts

all_unres = findings.select { |f| f[:resolved] == false }
puts "Unresolved names (not found in CRuby tree): #{all_unres.flat_map { |f| f[:unresolved_names] }.size}"
all_unres.flat_map { |f| f[:unresolved_names].map { |n| [n, f[:file], f[:line]] } }
         .first(opts[:samples] * 2).each { |n, file, line| puts "  #{n}  (#{file}:#{line})" }
puts

top = findings.group_by { |f| f[:file] }.transform_values(&:size).sort_by { |_, v| -v }.first(10)
puts 'Top files by reference count:'
top.each { |file, n| puts format('  %4d  %s', n, file) }
puts

# --- samples
shown = opts[:show].empty? ? cats : opts[:show]
shown.each do |cat|
  fs = findings.select { |f| f[:category] == cat }
  next if fs.empty?
  puts "--- #{cat} (#{fs.size}) samples"
  fs.first(opts[:samples]).each do |f|
    first_line = f[:comment].text.lines.first.strip
    tgt = f[:decl] ? "#{f[:decl][:kind]} #{f[:decl][:name]}" : '-'
    puts format('  %s:%d  [%s]  %s', f[:file], f[:line], tgt, first_line[0, 70])
    puts "      names=#{f[:refs][:names].inspect} rest=#{f[:refs][:rest].join(' | ')[0, 60].inspect}" unless cat == :clean
  end
  puts
end

# --- proposed diffs
if opts[:diff]
  puts '--- proposed edits (dry run, nothing written) ---'
  (auto_ok.empty? ? [] : auto_ok).first(opts[:samples] * 3).each do |f|
    d = f[:decl]
    puts "#{f[:file]}:#{f[:line]}  #{d[:kind]} #{d[:name]}  [#{f[:category]}]"
    f[:comment].text.lines.each { |l| puts "  - #{l.rstrip}" }
    puts "  + #{proposal(f, index)}"
    puts '  + (keep prose, remove MRI mention)' if f[:category] == :prose
    puts
  end
end

if opts[:tsv]
  File.open(opts[:tsv], 'w') do |io|
    io.puts %w[file line category target form names resolved files rest].join("\t")
    findings.each do |f|
      io.puts [f[:file], f[:line], f[:category], f[:decl] ? "#{f[:decl][:kind]}:#{f[:decl][:name]}" : '-',
               f[:refs][:form], f[:refs][:names].join(','), f[:resolved].inspect, f[:files].join(','),
               f[:refs][:rest].join(' | ').tr("\t\n", '  ')].join("\t")
    end
  end
  $stderr.puts "wrote #{opts[:tsv]}"
end
