#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_cloud_sync_icloud'
  s.version          = '0.1.0'
  s.summary          = 'iCloud provider for flutter_cloud_sync'
  s.description      = <<-DESC
iCloud Document Storage provider for flutter_cloud_sync.
Provides file upload/download/sync capabilities using iCloud Drive.
                       DESC
  s.homepage         = 'https://github.com/TNT-Likely/BeeCount'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'SmartBook' => 'contact@smartbook.app' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
