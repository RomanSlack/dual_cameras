Pod::Spec.new do |s|
  s.name             = 'dual_cameras_ios'
  s.version          = '0.1.0'
  s.summary          = 'iOS implementation of dual_cameras.'
  s.description      = <<-DESC
Front + back simultaneous camera recording and photo capture, composited on the
GPU (Metal) into a single video/photo via AVCaptureMultiCamSession.
                       DESC
  s.homepage         = 'https://github.com/RomanSlack/dual_cameras_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'RomanSlack' => 'romanslack@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
