#include "mac_activation.h"

#ifdef __APPLE__

#import <AppKit/AppKit.h>

void
sc_mac_set_accessory_activation(void) {
    // Выполнять только в главном потоке: AppKit этого требует.
    // Вызывается из main() до создания окна scrcpy.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

#else

void
sc_mac_set_accessory_activation(void) {
    // На других платформах иконки в Dock нет — делать нечего.
}

#endif
