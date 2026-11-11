# One-time edit of ios/Runner.xcodeproj that adds the ShareExtension target.
# Kept so the pbxproj change can be reproduced and reviewed, not to be re-run:
# it exits untouched if the target already exists.
#
# Run from the repository root with the xcodeproj gem CocoaPods bundles:
#   GEM_HOME="$(brew --prefix cocoapods)/libexec" ruby tool/add_share_extension.rb
# (or `gem install xcodeproj --user-install` and plain `ruby`).
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../ios/Runner.xcodeproj', __dir__)
TARGET_NAME = 'ShareExtension'

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == TARGET_NAME }
  puts "#{TARGET_NAME} already exists; nothing to do."
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' } or abort 'no Runner target'

# The extension's configurations sit on the same xcconfigs as Runner's, so they
# inherit NFAR_BUNDLE_ID, DEVELOPMENT_TEAM, FLUTTER_BUILD_NAME/NUMBER and, in
# Debug and Profile, the free-team LocalOverrides hook.
xcconfigs = {}
project.files.each do |f|
  next unless f.path&.start_with?('Flutter/') && f.path.end_with?('.xcconfig')
  xcconfigs[File.basename(f.path, '.xcconfig')] = f
end
%w[Debug Profile Release].each do |c|
  abort "no Flutter/#{c}.xcconfig reference" unless xcconfigs[c]
end

target = project.new_target(:app_extension, TARGET_NAME, :ios, '15.0')
# new_target links Foundation.framework by a path into one specific SDK
# version; Swift links it automatically, so drop the reference.
target.frameworks_build_phase.files.to_a.each do |bf|
  ref = bf.file_ref
  bf.remove_from_project
  ref.remove_from_project if ref && ref.build_files.empty?
end
project.frameworks_group.children.select { |g| g.display_name == 'iOS' && g.children.empty? }
       .each(&:remove_from_project)

group = project.main_group.new_group(TARGET_NAME, TARGET_NAME)
source = group.new_reference('ShareViewController.swift')
group.new_reference('Info.plist')
group.new_reference('ShareExtension.entitlements')
target.add_file_references([source])

target.build_configurations.each do |config|
  config.base_configuration_reference = xcconfigs.fetch(config.name)
  s = config.build_settings
  s['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
  s['CODE_SIGN_ENTITLEMENTS'] = '$(NFAR_SHARE_EXT_ENTITLEMENTS)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(NFAR_BUNDLE_ID).ShareExtension'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['SKIP_INSTALL'] = 'YES'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'
  ]
  # The xcconfigs pull in Pods-Runner.*.xcconfig, whose OTHER_LDFLAGS link the
  # plugin frameworks. Those live in Runner.app/Frameworks, are not extension
  # safe, and the extension uses none of them, so it links nothing extra.
  s['OTHER_LDFLAGS'] = ''
  s.delete('DEVELOPMENT_TEAM')
end

embed = runner.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins # dstSubfolderSpec 13
build_file = embed.add_file_reference(target.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
# Next to Embed Frameworks, ahead of Flutter's "Thin Binary" script: after it,
# Xcode reports a dependency cycle (the script reads the whole app bundle).
runner.build_phases.delete(embed)
frameworks = runner.build_phases.index { |p| p.display_name == 'Embed Frameworks' } or
  abort 'no Embed Frameworks phase'
runner.build_phases.insert(frameworks + 1, embed)

runner.add_dependency(target)

project.save
puts "Added #{TARGET_NAME}."
