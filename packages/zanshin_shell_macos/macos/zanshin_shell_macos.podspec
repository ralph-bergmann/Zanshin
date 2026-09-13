# SPDX-License-Identifier: MIT

Pod::Spec.new do |s|
  s.name             = 'zanshin_shell_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS implementation of the zanshin_shell plugin.'
  s.description      = 'macOS shell integration (system theme, window drag, folder drops) for Zanshin.'
  s.homepage         = 'https://example.com/zanshin'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Zanshin' => 'ralph@dasralph.de' }
  s.source           = { :path => '.' }
  # CocoaPods fallback only — the Swift Package at zanshin_shell_macos/ is the
  # primary integration and owns the same sources.
  s.source_files     = 'zanshin_shell_macos/Sources/zanshin_shell_macos/**/*'
  s.dependency 'FlutterMacOS'
  # Matches MACOSX_DEPLOYMENT_TARGET in app/macos/Runner.xcodeproj and the
  # `platform :osx` line of the Flutter-generated Podfile; a higher value here
  # would make CocoaPods reject the pod for the Runner target.
  s.platform         = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
