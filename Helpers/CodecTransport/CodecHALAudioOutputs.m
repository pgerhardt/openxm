#import "CodecAudioRoute.h"
#import <CoreAudio/CoreAudio.h>

static AudioObjectPropertyAddress RouteProperty(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
static UInt32 RouteInteger(AudioObjectID device, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress property = RouteProperty(selector);
    UInt32 value = 0, size = sizeof(value);
    return AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) == noErr ? value : 0;
}
static NSString *RouteString(AudioObjectID device, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress property = RouteProperty(selector);
    CFStringRef value = NULL; UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value) != noErr || !value) return nil;
    return CFBridgingRelease(value);
}

@implementation CodecHALAudioOutputs {
    AudioObjectPropertyListenerBlock _listener;
}
- (NSString *)currentOutputUID {
    return RouteString(RouteInteger(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice), kAudioDevicePropertyDeviceUID);
}
- (NSArray<CodecAudioOutput *> *)availableOutputs {
    AudioObjectPropertyAddress property = RouteProperty(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &size) != noErr || !size) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, data.mutableBytes) != noErr) return @[];
    NSMutableArray *outputs = [NSMutableArray new];
    const AudioObjectID *devices = data.bytes;
    for (NSUInteger i = 0; i < size / sizeof(AudioObjectID); i++) {
        AudioObjectID device = devices[i];
        if (!RouteInteger(device, kAudioDevicePropertyDeviceIsAlive)) continue;
        property = RouteProperty(kAudioDevicePropertyDeviceCanBeDefaultDevice); property.mScope = kAudioObjectPropertyScopeOutput;
        UInt32 eligible = 0, length = sizeof(eligible);
        if (AudioObjectGetPropertyData(device, &property, 0, NULL, &length, &eligible) != noErr || !eligible) continue;
        property = RouteProperty(kAudioDevicePropertyStreamConfiguration); property.mScope = kAudioObjectPropertyScopeOutput;
        if (AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &length) != noErr || length < sizeof(AudioBufferList)) continue;
        NSMutableData *buffers = [NSMutableData dataWithLength:length];
        if (AudioObjectGetPropertyData(device, &property, 0, NULL, &length, buffers.mutableBytes) != noErr) continue;
        const AudioBufferList *list = buffers.bytes; UInt32 channels = 0;
        for (UInt32 b = 0; b < list->mNumberBuffers; b++) channels += list->mBuffers[b].mNumberChannels;
        if (!channels) continue;
        NSString *uid = RouteString(device, kAudioDevicePropertyDeviceUID);
        if (!uid.length) continue;
        UInt32 transport = RouteInteger(device, kAudioDevicePropertyTransportType);
        CodecAudioOutput *output = [CodecAudioOutput new]; output.uid = uid;
        output.name = RouteString(device, kAudioObjectPropertyName) ?: @"audio output";
        switch (transport) {
            case kAudioDeviceTransportTypeBuiltIn: case kAudioDeviceTransportTypePCI:
            case kAudioDeviceTransportTypeUSB: case kAudioDeviceTransportTypeFireWire:
            case kAudioDeviceTransportTypeBluetooth: case kAudioDeviceTransportTypeBluetoothLE:
            case kAudioDeviceTransportTypeHDMI: case kAudioDeviceTransportTypeDisplayPort:
            case kAudioDeviceTransportTypeAirPlay: case kAudioDeviceTransportTypeAVB:
            case kAudioDeviceTransportTypeThunderbolt: case kAudioDeviceTransportTypeContinuityCaptureWired:
            case kAudioDeviceTransportTypeContinuityCaptureWireless: output.physical = YES; break;
            default: output.physical = NO; break;
        }
        output.wireless = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE ||
            transport == kAudioDeviceTransportTypeAirPlay || transport == kAudioDeviceTransportTypeContinuityCaptureWireless;
        output.builtIn = transport == kAudioDeviceTransportTypeBuiltIn;
        [outputs addObject:output];
    }
    return outputs;
}
- (BOOL)selectOutput:(NSString *)uid {
    // Resolve fresh IDs; Core Audio may reuse IDs across a Bluetooth reconnect.
    AudioObjectPropertyAddress property = RouteProperty(kAudioHardwarePropertyTranslateUIDToDevice);
    CFStringRef value = (__bridge CFStringRef)uid;
    AudioObjectID device = kAudioObjectUnknown; UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(value), &value, &size, &device) != noErr || !device) return NO;
    property = RouteProperty(kAudioHardwarePropertyDefaultOutputDevice);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, sizeof(device), &device) == noErr &&
        [[self currentOutputUID] isEqual:uid];
}
- (BOOL)startObserving:(void (^)(void))handler {
    [self stopObserving];
    _listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) { handler(); };
    AudioObjectPropertyAddress property = RouteProperty(kAudioHardwarePropertyDefaultOutputDevice);
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &property, dispatch_get_main_queue(), _listener) == noErr) return YES;
    _listener = nil; return NO;
}
- (void)stopObserving {
    if (!_listener) return;
    AudioObjectPropertyAddress property = RouteProperty(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &property, dispatch_get_main_queue(), _listener);
    _listener = nil;
}
- (void)dealloc { [self stopObserving]; }
@end
