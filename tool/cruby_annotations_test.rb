# Tests for tool/cruby_annotations.rb, against a small fake CRuby tree and Java fixtures.
#
#   bin/jruby tool/cruby_annotations_test.rb

require 'test/unit'
require 'tmpdir'
require 'open3'
require 'rbconfig'

class TestCRubyAnnotations < Test::Unit::TestCase
  SCRIPT = File.expand_path('cruby_annotations.rb', __dir__)

  CRUBY = {
    're.c' => <<~C,
      VALUE rb_cMatch;

      static VALUE
      match_begin(VALUE match, VALUE n)
      {
      }

      static VALUE
      match_size(VALUE match)
      {
      }

      static int
      dup_helper(void)
      {
      }
    C
    'array.c' => <<~C,
      static VALUE
      ary_reject_bang(VALUE ary)
      {
      }

      static int
      dup_helper(void)
      {
      }

      #define ARY_MAX_SIZE 100
    C
  }

  def setup
    @dir = Dir.mktmpdir
    @cruby = File.join(@dir, 'ruby')
    CRUBY.each { |name, src| write(File.join(@cruby, name), src) }
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_check_passes_for_valid_annotations
    java <<~JAVA
      @CRuby("rb_cMatch")
      class Good {
          @CRuby(value = "match_begin", file = "re.c")
          void begin() {}

          @CRuby("ARY_MAX_SIZE")
          static final int MAX = 100;

          @CRuby(value = "ary_reject_bang", file = "array.c")
          @org.jruby.anno.CRuby(value = "match_size", note = "size part")
          void both() {}
      }
    JAVA
    out, status = run_tool('check')
    assert_equal 0, status.exitstatus, out
    assert_match(/@CRuby annotations: 5  ok=5  ambiguous=0  wrong_file=0  missing=0/, out)
  end

  def test_check_fails_for_missing_name_and_wrong_file
    java <<~JAVA
      class Bad {
          @CRuby(value = "match_begin", file = "array.c")
          void wrongFile() {}

          @CRuby("rb_no_such_function")
          void missing() {}
      }
    JAVA
    out, status = run_tool('check')
    assert_equal 1, status.exitstatus, out
    assert_match(/Bad\.java:3 \[method wrongFile\] match_begin: file = "array.c", but defined in re.c/, out)
    assert_match(/Bad\.java:6 \[method missing\] rb_no_such_function: not defined in CRuby/, out)
  end

  def test_check_notes_ambiguous_name_without_failing
    java <<~JAVA
      class Ambiguous {
          @CRuby("dup_helper")
          void helper() {}

          @CRuby(value = "dup_helper", file = "array.c")
          void pinned() {}
      }
    JAVA
    out, status = run_tool('check')
    assert_equal 0, status.exitstatus, out
    assert_match(/note: .*Ambiguous\.java:3 \[method helper\] dup_helper: no file given; defined in/, out)
    assert_match(/ok=1  ambiguous=1/, out)
  end

  def test_survey_categories
    java <<~JAVA
      class Survey {
          // MRI: match_begin
          void clean() {}

          // MRI: ary_reject_bang and match_size
          void multi() {}

          /**
           * match_size
           *
           * Returns the number of groups.
           */
          void prose() {}

          // MRI: match_size, first half
          void qualified() {}

          // MRI doesn't do this
          void mention() {}

          void inner() {
              // MRI: match_begin
          }
      }
    JAVA
    out, status = run_tool('survey', '--tsv', tsv = File.join(@dir, 'out.tsv'))
    assert_equal 0, status.exitstatus, out
    rows = File.readlines(tsv).drop(1).map { |l| l.split("\t") }
    by_target = rows.to_h { |r| [r[3], r[2]] }
    assert_equal 'clean', by_target['method:clean']
    assert_equal 'multi', by_target['method:multi']
    assert_equal 'prose', by_target['method:prose']
    assert_equal 'qualified', by_target['method:qualified']
    assert_equal 'mention', by_target['method:mention']
    assert_equal ['inner'], rows.select { |r| r[3] == '-' }.map { |r| r[2] }
  end

  private

  def write(path, src)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, src)
  end

  def java(src)
    name = src[/class (\w+)/, 1]
    write(File.join(@dir, 'java', "#{name}.java"), "import org.jruby.anno.CRuby;\n#{src}")
  end

  def run_tool(command, *args)
    out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, command, '--ruby-src', @cruby, *args, File.join(@dir, 'java'))
    [out, status]
  end
end
