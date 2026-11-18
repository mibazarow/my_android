project('scrcpy', 'c',
        # Патч HARNES-S для my_android: app/src/mac_activation.m написан на
        # Objective-C (нужен AppKit), поэтому проект объявляет и objc.
        'objc',
        version: '4.1',
        meson_version: '>= 0.49',
        default_options: [
            'c_std=c11',
            'warning_level=2',
            'b_ndebug=if-release',
        ])


add_project_arguments('-Wmissing-prototypes', language: 'c')

if get_option('compile_app')
    subdir('app')
endif

if get_option('compile_server')
    subdir('server')
endif
