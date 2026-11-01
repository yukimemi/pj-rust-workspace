# Run with: ruby tests/release_hooks.rb
# Requires Ruby's standard library, kata, cargo, and jq. No signing credentials.
require 'yaml'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ReleaseHooksTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HOOK = 'scripts/ci/release-post-build.sh'
  PIN = 'deploy/macos/signing-cert.sha1'
  TARGET = 'aarch64-apple-darwin'

  def setup
    # Keep consumers and kata's registry inside this isolated checkout.
    @tmp = Dir.mktmpdir('.release-hooks-', ROOT)
    @consumer = File.join(@tmp, 'consumer')
    FileUtils.mkdir_p(@consumer)
    @config = { 'XDG_CONFIG_HOME' => File.join(@tmp, 'config'),
                'XDG_CACHE_HOME' => File.join(@tmp, 'cache'), 'KATA_NO_AUTOUPDATE' => '1' }
    @workflow = YAML.load_file(File.join(ROOT, '.github/workflows/release.yml.template'))
    @steps = @workflow.fetch('jobs').fetch('build').fetch('steps')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def step(name)
    @steps.find { |s| s['name'] == name } || raise("missing step #{name}")
  end

  def command(*args, env: {}, dir: @consumer)
    output, status = Open3.capture2e(@config.merge(env), *args, chdir: dir)
    assert status.success?, "#{args.first} failed: #{output}"
    output
  end

  def test_workflow_order_conditions_and_secret_scope
    names = ['Build workspace binaries', 'Require post-build hook when a signing pin exists',
             'Sign binaries (post-build hook)', 'Stage release artifacts',
             'Verify packaged signatures (post-build hook)']
    indices = names.map { |name| @steps.index(step(name)) }
    upload = @steps.index { |s| s['uses']&.start_with?('actions/upload-artifact@') }
    assert_equal (indices + [upload]).sort, indices + [upload]
    %w[release publish].each do |job|
      assert_equal 'build', @workflow['jobs'][job]['needs']
    end
    guard = step(names[1])
    refute guard.key?('continue-on-error')
    assert_equal "${{ hashFiles('#{PIN}') != '' && hashFiles('#{HOOK}') == '' }}", guard['if']
    [names[2], names[4]].each do |name|
      assert_equal "${{ hashFiles('#{HOOK}') != '' }}", step(name)['if']
      refute step(name).key?('continue-on-error')
    end
    assert_equal "bash #{HOOK} sign", step(names[2])['run']
    assert_equal "bash #{HOOK} verify-dist", step(names[4])['run']
    assert_equal({ 'TARGET' => '${{ matrix.target }}' }, step(names[4])['env'])
    secrets = %w[MACOS_SIGN_CERT_P12_BASE64 MACOS_SIGN_CERT_PASSWORD]
    secrets.each do |secret|
      assert_equal "${{ secrets.#{secret} }}", step(names[2])['env'][secret]
      assert_equal 1, File.read(File.join(ROOT, '.github/workflows/release.yml.template')).scan("secrets.#{secret}").size
    end
    assert_equal({ 'CARGO_TERM_COLOR' => 'always' }, @workflow['env'])
    refute @workflow['jobs']['build'].key?('env')
    @steps.each do |s|
      next unless s['run']
      command('bash', '-n', '-c', s['run'])
    end
  end

  def test_kata_regeneration_preserves_consumer_contract
    preset = File.join(@tmp, 'preset.toml')
    File.write(preset, %(name = "release-test"\n[[templates]]\nsource = #{ROOT.inspect}\n))
    command('kata', 'init', preset, '--at', @consumer, '--non-interactive', '--no-ai')
    generated = File.join(@consumer, '.github/workflows/release.yml')
    assert_equal File.binread(File.join(ROOT, '.github/workflows/release.yml.template')), File.binread(generated)
    [HOOK, PIN].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@consumer, path)))
      File.write(File.join(@consumer, path), "consumer-owned\n")
    end
    2.times do
      File.write(generated, "local edit must be replaced\n")
      command('kata', 'apply', '--at', @consumer, '--non-interactive', '--no-ai')
      assert_equal File.binread(File.join(ROOT, '.github/workflows/release.yml.template')), File.binread(generated)
      [HOOK, PIN].each { |path| assert_equal "consumer-owned\n", File.read(File.join(@consumer, path)) }
    end
  end

  def test_release_failures_block_upload_and_packaging_uses_signed_bytes
    # Exercise the actual shell bodies in workflow order. Conditions below
    # model only the exact hashFiles expressions asserted in the structure test.
    [false, true].product([false, true]).each do |pin, hook|
      [nil, 'sign', 'verify-dist'].each do |failure|
        FileUtils.rm_rf(Dir.glob(File.join(@consumer, '*')))
        if pin
          FileUtils.mkdir_p(File.join(@consumer, File.dirname(PIN)))
          File.write(File.join(@consumer, PIN), "test pin\n")
        end
        if hook
          FileUtils.mkdir_p(File.join(@consumer, File.dirname(HOOK)))
          File.write(File.join(@consumer, HOOK), <<~SH)
            set -euo pipefail
            test "$TARGET" = #{TARGET}
            if [ "$1" = sign ]; then
              test "$MACOS_SIGN_CERT_P12_BASE64" = test-cert
              test "$MACOS_SIGN_CERT_PASSWORD" = test-password
              test "${FAIL_PHASE:-}" != sign
              printf signed > target/$TARGET/release/demo
            else
              test "${MACOS_SIGN_CERT_P12_BASE64+x}" != x
              test "${MACOS_SIGN_CERT_PASSWORD+x}" != x
              test "${FAIL_PHASE:-}" != verify-dist
              test "$(tar xOf dist/demo-$TARGET.tar.gz demo-$TARGET)" = signed
              test "$(tar tzf dist/demo-$TARGET.tar.gz)" = demo-$TARGET
            fi
          SH
        end
        FileUtils.mkdir_p(File.join(@consumer, "target/#{TARGET}/release"))
        File.write(File.join(@consumer, "target/#{TARGET}/release/demo"), 'unsigned')
        # Avoid compiling a workspace: staging only needs cargo metadata.
        bin = File.join(@consumer, 'mock-bin')
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, 'cargo'), "#!/bin/sh\nprintf '%s' '{\"packages\":[{\"targets\":[{\"kind\":[\"bin\"],\"name\":\"demo\"}]}]}'\n")
        FileUtils.chmod(0755, File.join(bin, 'cargo'))
        passed = true
        @steps.drop_while { |s| s['name'] != 'Require post-build hook when a signing pin exists' }.each do |s|
          if s['uses']&.start_with?('actions/upload-artifact@')
            File.write(File.join(@consumer, 'uploaded'), '')
            break
          end
          next if s['if'] && (s['name'].start_with?('Require') ? !(pin && !hook) : !hook)
          env = { 'TARGET' => TARGET, 'FAIL_PHASE' => failure.to_s,
                  'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
                  'MACOS_SIGN_CERT_P12_BASE64' => nil, 'MACOS_SIGN_CERT_PASSWORD' => nil }
          if s['name'] == 'Sign binaries (post-build hook)'
            env.merge!('MACOS_SIGN_CERT_P12_BASE64' => 'test-cert', 'MACOS_SIGN_CERT_PASSWORD' => 'test-password')
          end
          _, status = Open3.capture2e(env, 'bash', '-e', '-o', 'pipefail', '-c', s.fetch('run'), chdir: @consumer)
          passed = status.success?
          break unless passed
        end
        expected = !(pin && !hook) && !(hook && failure)
        assert_equal expected, passed, "pin=#{pin} hook=#{hook} failure=#{failure}"
        assert_equal expected, File.exist?(File.join(@consumer, 'uploaded'))
        if (pin && !hook) || (hook && failure == 'sign')
          refute Dir.exist?(File.join(@consumer, 'dist')), 'failure must precede packaging'
        end
      end
    end
  end
end
