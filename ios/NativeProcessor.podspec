Pod::Spec.new do |s|
  s.name             = 'NativeProcessor'
  s.version          = '1.0.0'
  s.summary          = 'iCamera native C++ image processing pipeline'
  s.homepage         = 'https://github.com/tcw3/icamera'
  s.license          = { :type => 'MIT' }
  s.author           = { 'iCamera' => 'dev@icamera.app' }
  s.source           = { :path => '.' }

  # All C++ source files live one directory above ios/
  s.source_files     = '../native/*.{cpp,h}'
  s.public_header_files = '../native/icamera_native.h'

  s.ios.deployment_target = '13.0'

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_CPLUSPLUSFLAGS' => '-O3 -ffast-math -funroll-loops -fvisibility=hidden',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    # Disable bitcode (deprecated in Xcode 14+)
    'ENABLE_BITCODE' => 'NO',
  }
end
