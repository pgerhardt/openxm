// Real LDAC encoders with synthetic PCM/queue depth; never connects to hardware.
#import "CodecStreamSettings.h"
#include "ldac_a2dp.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "Codec settings test failed at line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

static void SettingsAreValidatedAndMatched(void) {
    NSDictionary *valid = @{@"revision": @2, @"ldacQuality": @0, @"sampleRate": @48000, @"fastRecovery": @YES};
    CodecStreamSettings *settings = [CodecStreamSettings fromDictionary:valid];
    CHECK(settings && settings.revision == 2);
    for (NSDictionary *replacement in @[@{@"revision": @(-1)}, @{@"ldacQuality": @3}, @{@"sampleRate": @96000}, @{@"sampleRate": @44100.1}, @{@"fastRecovery": @1}, @{@"ldacQuality": @YES}]) {
        NSMutableDictionary *bad = valid.mutableCopy; [bad addEntriesFromDictionary:replacement];
        CHECK(![CodecStreamSettings fromDictionary:bad]);
    }
    CHECK(![CodecStreamSettings fromDictionary:@{}]);
    A2DPCodec *ldac = [A2DPCodec codecWithID:CodecIDLDAC];
    CodecOptions *options = [settings optionsForCodec:CodecIDLDAC];
    CodecOptions *copied = [options copy]; CHECK(copied.ldacFastRecovery);
    CodecConfiguration *configuration = [ldac configurationForCapability:ldac.fullCapabilityElement sampleRate:48000 options:options];
    CHECK([settings matchesConfiguration:configuration codec:CodecIDLDAC]);
    configuration = [ldac configurationForCapability:ldac.fullCapabilityElement sampleRate:44100 options:options];
    CHECK(![settings matchesConfiguration:configuration codec:CodecIDLDAC]);
    options.presets = @{CodecIDLDAC: @1};
    configuration = [ldac configurationForCapability:ldac.fullCapabilityElement sampleRate:48000 options:options];
    CHECK(![settings matchesConfiguration:configuration codec:CodecIDLDAC]);
}

static void FixedQualityIgnoresBacklogAtBothRates(void) {
    A2DPCodec *ldac = [A2DPCodec codecWithID:CodecIDLDAC];
    int expected[2][3] = {{909, 606, 303}, {990, 660, 330}};
    for (int family = 0; family < 2; family++) for (int quality = 0; quality < 3; quality++) {
        double rate = family ? 48000 : 44100;
        CodecOptions *options = [CodecOptions new]; options.presets = @{CodecIDLDAC: @(quality)};
        CodecConfiguration *config = [ldac configurationForCapability:ldac.fullCapabilityElement sampleRate:rate options:options];
        NSString *error = nil;
        id<A2DPEncoder> encoder = [ldac encoderForConfiguration:config outMTU:895 options:options error:&error];
        CHECK(encoder && !error && (int)encoder.bitrateKbps == expected[family][quality]);
        uint8_t pcm[128 * 6] = {0}; size_t packets = 0;
        for (int i = 0; i < 400; i++) {
            [encoder reportQueueDepth:100];
            NSArray *encoded = [encoder encode:pcm error:&error];
            CHECK(encoded && !error); packets += encoded.count;
            CHECK((int)encoder.bitrateKbps == expected[family][quality]);
        }
        CHECK(packets > 0);
    }
}

static void BackoffBoundsAndActualFailedProbe(void) {
    for (int fast = 0; fast < 2; fast++) {
        char error[200] = {0};
        ldac_a2dp *codec = ldac_a2dp_open(44100, kLdacChannelStereo, kLdacQualityABR, 883, error, sizeof(error));
        CHECK(codec);
        if (fast) CHECK(ldac_a2dp_set_abr_backoff(codec, 1, 5) == 0);
        CHECK(ldac_a2dp_set_abr_backoff(codec, NAN, 5) < 0);
        CHECK(ldac_a2dp_set_abr_backoff(codec, 5, 1) < 0);
        uint8_t pcm[128 * 6] = {0}, packet[895]; size_t frames = 0;
        int blocked = 0; double seconds = 0;
        for (int i = 0; i < 100 && !blocked; i++) {
            ldac_a2dp_set_queue_depth(codec, 100);
            CHECK(ldac_a2dp_encode(codec, pcm, packet, sizeof(packet), &frames, error, sizeof(error)) >= 0);
            ldac_a2dp_take_abr_block(codec, &blocked, &seconds);
        }
        CHECK(blocked == 606 && seconds == (fast ? 1 : 30));
        ldac_abr_guard carried = {1, 299, 300, 0}, actual;
        ldac_a2dp_set_abr_guard(codec, &carried); ldac_a2dp_get_abr_guard(codec, &actual);
        CHECK(actual.remaining <= (fast ? 5 : 300));
        CHECK(actual.backoff == (fast ? 5 : 300));
        ldac_a2dp_close(codec);
    }
}

int main(void) {
    @autoreleasepool {
        SettingsAreValidatedAndMatched(); FixedQualityIgnoresBacklogAtBothRates(); BackoffBoundsAndActualFailedProbe();
        puts("3 codec settings tests passed (6 fixed LDAC configurations, both Auto backoffs; no live changes).");
    }
    return 0;
}
